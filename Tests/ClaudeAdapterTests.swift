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
        failures += check("limits[] weekly_scoped Fable → tertiary ring") {
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
                  "percent": 12,
                  "is_active": true,
                  "scope": { "model": { "display_name": "Other" } }
                }
              ]
            }
            """
            let snap = ClaudeAdapter.parseUsageResponse(data: Data(json.utf8), plan: nil)
            try assertEqual(snap.primary.usedFraction, 0.10, accuracy: 0.0001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0.20, accuracy: 0.0001)
            try assertEqual(snap.tertiary?.displayLabel, "Fable")
            try assertEqual(snap.tertiary?.usedFraction ?? -1, 0.38, accuracy: 0.0001)
            // Non-Fable scoped stays as hover extra.
            try assertEqual(Double(snap.extras.count), 1, accuracy: 0)
            try assertEqual(snap.extras[0].displayLabel, "Other")
            // Burn stays on 5h — tertiary excluded.
            try assertEqual(snap.preferredBurnWindow.kind, UsageWindowKind.fiveHour)
        }
        failures += check("inactive Fable still promoted (live Max shape)") {
            // Live accounts often send is_active:false with a real Fable percent.
            let json = """
            {
              "five_hour": { "utilization": 3 },
              "seven_day": { "utilization": 28 },
              "limits": [
                { "kind": "session", "percent": 3, "is_active": false },
                { "kind": "weekly_all", "percent": 28, "is_active": true },
                {
                  "kind": "weekly_scoped",
                  "percent": 1,
                  "is_active": false,
                  "resets_at": "2026-08-16T20:00:00Z",
                  "scope": { "model": { "display_name": "Fable" } }
                }
              ]
            }
            """
            let snap = ClaudeAdapter.parseUsageResponse(data: Data(json.utf8), plan: nil)
            try assertEqual(snap.tertiary?.displayLabel, "Fable")
            try assertEqual(snap.tertiary?.usedFraction ?? -1, 0.01, accuracy: 0.0001)
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
        failures += check("always probe; refresh only after usage 401") {
            let now = Date()
            let future = now.addingTimeInterval(30 * 60)
            let slightlyPast = now.addingTimeInterval(-10 * 60)
            let hoursPast = now.addingTimeInterval(-3 * 3600)
            let fresh = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: "r", subscriptionType: nil, expiresAt: future, rawJSON: nil
            )
            let softExpired = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: "r", subscriptionType: nil, expiresAt: slightlyPast, rawJSON: nil
            )
            let hoursDead = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: "r", subscriptionType: nil, expiresAt: hoursPast, rawJSON: nil
            )
            let noRefresh = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: nil, subscriptionType: nil, expiresAt: slightlyPast, rawJSON: nil
            )
            try assertTrue(ClaudeAdapter.shouldProbeBeforeRefresh(fresh))
            try assertTrue(ClaudeAdapter.shouldProbeBeforeRefresh(softExpired))
            try assertTrue(ClaudeAdapter.shouldProbeBeforeRefresh(hoursDead))
            try assertTrue(!ClaudeAdapter.shouldAttemptRefresh(after: nil, credentials: fresh, now: now))
            try assertTrue(
                !ClaudeAdapter.shouldAttemptRefresh(
                    after: .rateLimited(retryAfter: nil),
                    credentials: softExpired,
                    now: now
                )
            )
            try assertTrue(ClaudeAdapter.shouldAttemptRefresh(after: .authRequired, credentials: softExpired, now: now))
            try assertTrue(ClaudeAdapter.shouldAttemptRefresh(after: .authRequired, credentials: hoursDead, now: now))
            try assertTrue(!ClaudeAdapter.shouldAttemptRefresh(after: .authRequired, credentials: noRefresh, now: now))
            try assertTrue(ClaudeAdapter.needsRefresh(fresh) == false)
            try assertTrue(ClaudeAdapter.needsRefresh(softExpired))
            try assertTrue(ClaudeAdapter.needsRefresh(noRefresh) == false)
        }
        failures += check("managed-file adoption requires a rotated access token") {
            let current = ClaudeAdapter.ClaudeCreds(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                subscriptionType: "max",
                expiresAt: Date().addingTimeInterval(3600),
                rawJSON: nil
            )
            try assertTrue(ClaudeAdapter.shouldAdopt(current, failedAccessToken: "old-access"))
            try assertTrue(!ClaudeAdapter.shouldAdopt(current, failedAccessToken: "new-access"))
            try assertTrue(!ClaudeAdapter.shouldAdopt(current, failedAccessToken: nil))
        }
        failures += check("reauth rejects leftover access even with future expiresAt") {
            // 8148deb: leftover same access after snapshot, even when expiresAt is +1h.
            let leftover = ClaudeAdapter.ClaudeCreds(
                accessToken: "old-access",
                refreshToken: "rt",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(3600),
                rawJSON: nil
            )
            try assertTrue(!ClaudeAdapter.isAcceptableLogin(leftover, priorAccessToken: "old-access"))
            try assertTrue(!ClaudeAdapter.isAcceptableLogin(
                leftover,
                priorAccessToken: "old-access",
                priorRefreshToken: "rt"
            ))
            // beginAdd (prior nil) still accepts any non-empty harvest.
            try assertTrue(ClaudeAdapter.isAcceptableLogin(leftover, priorAccessToken: nil))
            try assertTrue(!ClaudeAdapter.isAcceptableLogin(
                ClaudeAdapter.ClaudeCreds(
                    accessToken: "",
                    refreshToken: nil,
                    subscriptionType: nil,
                    expiresAt: nil,
                    rawJSON: nil
                ),
                priorAccessToken: nil
            ))
        }
        failures += check("reauth rejects leftover session that only rotated access (H1)") {
            // Same refresh_token + new access = leftover grant, not a new login.
            let rotatedLeftover = ClaudeAdapter.ClaudeCreds(
                accessToken: "new-access",
                refreshToken: "rt-same",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(3600),
                rawJSON: nil
            )
            try assertTrue(!ClaudeAdapter.isAcceptableLogin(
                rotatedLeftover,
                priorAccessToken: "old-access",
                priorRefreshToken: "rt-same"
            ))
            // New access *and* new refresh is a real session (browser reauth).
            let fresh = ClaudeAdapter.ClaudeCreds(
                accessToken: "new-access",
                refreshToken: "rt-new",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(3600),
                rawJSON: nil
            )
            try assertTrue(ClaudeAdapter.isAcceptableLogin(
                fresh,
                priorAccessToken: "old-access",
                priorRefreshToken: "rt-same"
            ))
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
        failures += check("credentials are file-only (no keychain helper)") {
            let dir = URL(fileURLWithPath: "/tmp/dash-island-test-config-missing", isDirectory: true)
            try assertTrue(ClaudeAdapter.readCredentials(configDir: dir) == nil)
            try assertTrue(ClaudeAdapter.readCredentialsFile(configDir: dir) == nil)
        }
        failures += check("scoped keychain service is stable 8-hex suffix") {
            let dir = URL(fileURLWithPath: "/tmp/dash-island-test-config", isDirectory: true)
            let service = ClaudeAdapter.scopedKeychainService(for: dir)
            try assertTrue(service.hasPrefix("Claude Code-credentials-"))
            let suffix = String(service.dropFirst("Claude Code-credentials-".count))
            try assertEqual(suffix.count, 8)
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
        failures += check("hours-dead access still may refresh when refresh_token present") {
            // Was a hard 45m cut — left accounts permanently quiet after 429 windows.
            let expMs = Int((Date().timeIntervalSince1970 - 3 * 3600) * 1000) // 3h dead
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-oat01-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","refreshToken":"sk-ant-ort01-refresh-token-value-here-xxxx","expiresAt":\(expMs)}}
            """
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))!
            try assertTrue(!ClaudeAdapter.isHardExpired(creds), "3h is within week stale window")
            try assertTrue(ClaudeAdapter.canAttemptRefresh(creds))
            try assertTrue(ClaudeAdapter.shouldRefresh(creds))
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
        failures += check("week-old access is hard-expired") {
            let expMs = Int((Date().timeIntervalSince1970 - 10 * 24 * 3600) * 1000)
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-oat01-cccccccccccccccccccccccccccccccccccccccc","refreshToken":"sk-ant-ort01-refresh-token-value-here-zzzz","expiresAt":\(expMs)}}
            """
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))!
            try assertTrue(ClaudeAdapter.isHardExpired(creds))
            try assertTrue(!ClaudeAdapter.canAttemptRefresh(creds))
        }
        failures += check("soft error must not become last-good retainable") {
            let errSnap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0, kind: .fiveHour),
                secondary: nil,
                plan: nil,
                fetchedAt: Date(),
                error: .rateLimited(retryAfter: nil)
            )
            try assertTrue(!UsageSnapshotMerge.shouldRetainPreviousRings(previous: errSnap))
            let good = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.42, kind: .fiveHour),
                secondary: nil,
                plan: "pro",
                fetchedAt: Date()
            )
            try assertTrue(UsageSnapshotMerge.shouldRetainPreviousRings(previous: good))
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
            let a = URL(fileURLWithPath: "/tmp/dash-claude-acct-a", isDirectory: true)
            let b = URL(fileURLWithPath: "/tmp/dash-claude-acct-b", isDirectory: true)
            try assertTrue(a.path != b.path)
            let fileA = a.appendingPathComponent(".credentials.json")
            let fileB = b.appendingPathComponent(".credentials.json")
            try assertTrue(fileA.path != fileB.path)
            try assertTrue(ClaudeAdapter.readCredentials(configDir: a) == nil)
            try assertTrue(ClaudeAdapter.readCredentials(configDir: b) == nil)
        }
        failures += check("scoped keychain service never targets the unsuffixed default item") {
            let a = try makeTempDir()
            let b = try makeTempDir()
            defer {
                try? FileManager.default.removeItem(at: a)
                try? FileManager.default.removeItem(at: b)
            }
            let svcA = ClaudeAdapter.scopedKeychainService(for: a)
            let svcB = ClaudeAdapter.scopedKeychainService(for: b)
            try assertTrue(svcA != svcB, "distinct dirs must hash to distinct services")
            try assertTrue(svcA.hasPrefix("Claude Code-credentials-"))
            try assertTrue(svcB.hasPrefix("Claude Code-credentials-"))
            try assertEqual(String(svcA.dropFirst("Claude Code-credentials-".count)).count, 8)
            try assertTrue(svcA != "Claude Code-credentials")
            try assertTrue(svcB != "Claude Code-credentials")
            try assertTrue(!svcA.hasSuffix("-"))
        }
        failures += check("existingAccessToken / capture prefer the managed file") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try assertTrue(ClaudeAdapter.existingAccessToken(configDir: dir) == nil)
            try assertTrue(ClaudeAdapter.captureLoginCredentials(configDir: dir) == nil)
            try assertTrue(ClaudeAdapter.readCredentials(configDir: dir) == nil)

            let written = ClaudeAdapter.ClaudeCreds(
                accessToken: "file-access-A",
                refreshToken: "file-refresh-A",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(3600),
                rawJSON: nil
            )
            ClaudeAdapter.persistCredentialsFile(creds: written, configDir: dir, overwrite: true)
            try assertEqual(ClaudeAdapter.existingAccessToken(configDir: dir), "file-access-A")
            try assertEqual(ClaudeAdapter.captureLoginCredentials(configDir: dir)?.accessToken, "file-access-A")
            try assertEqual(ClaudeAdapter.readCredentials(configDir: dir)?.refreshToken, "file-refresh-A")
        }
        failures += check("clearManagedCredentials deletes the file and last-good (H6)") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let creds = ClaudeAdapter.ClaudeCreds(
                accessToken: "wipe-me",
                refreshToken: "rt",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(3600),
                rawJSON: nil
            )
            ClaudeAdapter.persistCredentialsFile(creds: creds, configDir: dir, overwrite: true)
            let good = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.42, kind: .fiveHour),
                secondary: nil,
                plan: "pro",
                fetchedAt: Date()
            )
            let lastGoodURL = CredentialStore.lastGoodUsageURL(inDirectory: dir)
            try assertTrue(UsageOrchestrator.saveLastGood(good, to: lastGoodURL))
            try assertTrue(FileManager.default.fileExists(atPath: lastGoodURL.path))

            ClaudeAdapter.clearManagedCredentials(configDir: dir)

            try assertTrue(ClaudeAdapter.readCredentialsFile(configDir: dir) == nil)
            try assertTrue(ClaudeAdapter.existingAccessToken(configDir: dir) == nil)
            try assertTrue(!FileManager.default.fileExists(atPath: lastGoodURL.path))
            // Wipe must not invent a global Keychain service name.
            try assertTrue(ClaudeAdapter.scopedKeychainService(for: dir) != "Claude Code-credentials")
        }
        failures += check("reauth composition: snapshot → wipe → leftover vs new session") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let prior = ClaudeAdapter.ClaudeCreds(
                accessToken: "access-A",
                refreshToken: "refresh-A",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(3600),
                rawJSON: nil
            )
            ClaudeAdapter.persistCredentialsFile(creds: prior, configDir: dir, overwrite: true)
            let snap = ClaudeAdapter.existingCredentials(configDir: dir)
            try assertEqual(snap?.accessToken, "access-A")
            try assertEqual(snap?.refreshToken, "refresh-A")

            ClaudeAdapter.clearManagedCredentials(configDir: dir)
            try assertTrue(ClaudeAdapter.readCredentials(configDir: dir) == nil)

            let leftoverSameAccess = ClaudeAdapter.ClaudeCreds(
                accessToken: "access-A",
                refreshToken: "refresh-A",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(7200),
                rawJSON: nil
            )
            try assertTrue(!ClaudeAdapter.isAcceptableLogin(
                leftoverSameAccess,
                priorAccessToken: snap?.accessToken,
                priorRefreshToken: snap?.refreshToken
            ))

            let leftoverRotatedAccess = ClaudeAdapter.ClaudeCreds(
                accessToken: "access-B",
                refreshToken: "refresh-A",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(7200),
                rawJSON: nil
            )
            try assertTrue(!ClaudeAdapter.isAcceptableLogin(
                leftoverRotatedAccess,
                priorAccessToken: snap?.accessToken,
                priorRefreshToken: snap?.refreshToken
            ))

            let fresh = ClaudeAdapter.ClaudeCreds(
                accessToken: "access-B",
                refreshToken: "refresh-B",
                subscriptionType: "pro",
                expiresAt: Date().addingTimeInterval(7200),
                rawJSON: nil
            )
            try assertTrue(ClaudeAdapter.isAcceptableLogin(
                fresh,
                priorAccessToken: snap?.accessToken,
                priorRefreshToken: snap?.refreshToken
            ))
            ClaudeAdapter.persistCredentialsFile(creds: fresh, configDir: dir, overwrite: true)
            try assertEqual(ClaudeAdapter.readCredentials(configDir: dir)?.accessToken, "access-B")
        }
        failures += check("shouldAttemptRefresh: 401 only; never 429/nil; long-lived and 7d stale") {
            let now = Date()
            let live = ClaudeAdapter.ClaudeCreds(
                accessToken: "a",
                refreshToken: "r",
                subscriptionType: nil,
                expiresAt: now.addingTimeInterval(3600),
                rawJSON: nil
            )
            let longLived = ClaudeAdapter.ClaudeCreds(
                accessToken: "sk-ant-oat01-" + String(repeating: "x", count: 80),
                refreshToken: nil,
                subscriptionType: nil,
                expiresAt: nil,
                longLived: true,
                rawJSON: nil
            )
            let weekStale = ClaudeAdapter.ClaudeCreds(
                accessToken: "a",
                refreshToken: "r",
                subscriptionType: nil,
                expiresAt: now.addingTimeInterval(-8 * 24 * 3600),
                rawJSON: nil
            )
            try assertTrue(!ClaudeAdapter.shouldAttemptRefresh(after: nil, credentials: live, now: now))
            try assertTrue(!ClaudeAdapter.shouldAttemptRefresh(
                after: .rateLimited(retryAfter: nil),
                credentials: live,
                now: now
            ))
            try assertTrue(ClaudeAdapter.shouldAttemptRefresh(after: .authRequired, credentials: live, now: now))
            // Probe maps 403 → authRequired; that is the 403-as-refresh path.
            try assertTrue(!ClaudeAdapter.shouldAttemptRefresh(after: .authRequired, credentials: longLived, now: now))
            try assertTrue(!ClaudeAdapter.shouldAttemptRefresh(after: .authRequired, credentials: weekStale, now: now))
            try assertTrue(!ClaudeAdapter.canAttemptRefresh(weekStale, now: now))
        }
        failures += check("shouldAdopt only when failed access is set and differs") {
            let creds = ClaudeAdapter.ClaudeCreds(
                accessToken: "live",
                refreshToken: "r",
                subscriptionType: nil,
                expiresAt: Date().addingTimeInterval(3600),
                rawJSON: nil
            )
            try assertTrue(ClaudeAdapter.shouldAdopt(creds, failedAccessToken: "dead"))
            try assertTrue(!ClaudeAdapter.shouldAdopt(creds, failedAccessToken: "live"))
            try assertTrue(!ClaudeAdapter.shouldAdopt(creds, failedAccessToken: nil))
            try assertTrue(!ClaudeAdapter.shouldAdopt(creds, failedAccessToken: ""))
            // H8: adopted + 401 does not POST — refreshThenProbe only re-probes on .adopted.
            // Locked here as the helper contract (no live token host).
        }
        failures += check("usage smoke decision: 401 reject; 429/network soft keep; 200 pass (H2)") {
            let ok = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.1, kind: .fiveHour),
                secondary: nil,
                plan: "pro",
                fetchedAt: Date()
            )
            try assertEqual(ClaudeAdapter.usageSmokeDecision(ok), ClaudeAdapter.UsageSmokeDecision.pass)
            try assertEqual(
                ClaudeAdapter.usageSmokeDecision(
                    UsageSnapshot(
                        primary: WindowUsage(usedFraction: 0, kind: .unknown),
                        secondary: nil,
                        plan: nil,
                        fetchedAt: Date(),
                        error: .authRequired
                    )
                ),
                ClaudeAdapter.UsageSmokeDecision.reject
            )
            try assertEqual(
                ClaudeAdapter.usageSmokeDecision(
                    UsageSnapshot(
                        primary: WindowUsage(usedFraction: 0, kind: .unknown),
                        secondary: nil,
                        plan: nil,
                        fetchedAt: Date(),
                        error: .rateLimited(retryAfter: nil)
                    )
                ),
                ClaudeAdapter.UsageSmokeDecision.softKeep
            )
            try assertEqual(
                ClaudeAdapter.usageSmokeDecision(
                    UsageSnapshot(
                        primary: WindowUsage(usedFraction: 0, kind: .unknown),
                        secondary: nil,
                        plan: nil,
                        fetchedAt: Date(),
                        error: .network("timeout")
                    )
                ),
                ClaudeAdapter.UsageSmokeDecision.softKeep
            )
        }
        failures += check("setup-token paste policy in a temp dir") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try assertTrue(ClaudeAdapter.normalizePastedToken("sk-ant-oat01-tooshort") == nil)
            try assertTrue(ClaudeAdapter.normalizePastedToken("garbage") == nil)
            let tok = "sk-ant-oat01-" + String(repeating: "z", count: 80)
            try ClaudeAdapter.installSetupToken(tok, configDir: dir)
            let installed = ClaudeAdapter.readCredentials(configDir: dir)
            try assertTrue(installed != nil)
            try assertTrue(ClaudeAdapter.isLongLived(installed!))
            try assertTrue(!ClaudeAdapter.shouldAttemptRefresh(
                after: .authRequired,
                credentials: installed!
            ))
            let oatWithRefresh = ClaudeAdapter.ClaudeCreds(
                accessToken: tok,
                refreshToken: "sk-ant-ort01-refresh-token-value-here",
                subscriptionType: nil,
                expiresAt: Date().addingTimeInterval(-60),
                rawJSON: nil
            )
            try assertTrue(ClaudeAdapter.looksLikeSetupToken(tok))
            try assertTrue(!ClaudeAdapter.isLongLived(oatWithRefresh))
        }
        failures += check("requireCredentials is file-only (H10)") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            do {
                _ = try ClaudeAdapter.requireCredentials(configDir: dir)
                try assertTrue(false, "empty dir must not harvest a leftover session")
            } catch let error as ClaudeAdapterError {
                try assertEqual(error, ClaudeAdapterError.credentialsMissing(configDir: dir.path))
            }
            ClaudeAdapter.persistCredentialsFile(
                creds: ClaudeAdapter.ClaudeCreds(
                    accessToken: "file-only",
                    refreshToken: "rt",
                    subscriptionType: "pro",
                    expiresAt: Date().addingTimeInterval(3600),
                    rawJSON: nil
                ),
                configDir: dir,
                overwrite: true
            )
            try assertEqual(try ClaudeAdapter.requireCredentials(configDir: dir).accessToken, "file-only")
        }
        failures += check("failed reauth rollback wipes a smoke-rejected harvest") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            ClaudeAdapter.persistCredentialsFile(
                creds: ClaudeAdapter.ClaudeCreds(
                    accessToken: "rejected-harvest",
                    refreshToken: "rt-new",
                    subscriptionType: "pro",
                    expiresAt: Date().addingTimeInterval(3600),
                    rawJSON: nil
                ),
                configDir: dir,
                overwrite: true
            )
            let lastGood = CredentialStore.lastGoodUsageURL(inDirectory: dir)
            let snap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.2, kind: .fiveHour),
                secondary: nil,
                plan: "pro",
                fetchedAt: Date()
            )
            try assertTrue(UsageOrchestrator.saveLastGood(snap, to: lastGood))
            // Same helper reauthenticate/beginAdd catch now call after smoke reject.
            ClaudeAdapter.clearManagedCredentials(configDir: dir)
            try assertTrue(ClaudeAdapter.readCredentials(configDir: dir) == nil)
            try assertTrue(!FileManager.default.fileExists(atPath: lastGood.path))
        }
        failures += check("last-good encode/decode refuses error snapshots") {
            let errSnap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0, kind: .fiveHour),
                secondary: nil,
                plan: nil,
                fetchedAt: Date(),
                error: .authRequired
            )
            try assertTrue(UsageOrchestrator.encodeLastGood(errSnap) == nil)
            let good = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.5, kind: .fiveHour),
                secondary: nil,
                plan: "max",
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            guard let data = UsageOrchestrator.encodeLastGood(good) else {
                try assertTrue(false, "expected encode")
                return
            }
            try assertEqual(UsageOrchestrator.decodeLastGood(data)?.plan, "max")
            // Decode must drop a payload that carries an error.
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let dirty = try encoder.encode(errSnap)
            try assertTrue(UsageOrchestrator.decodeLastGood(dirty) == nil)
        }
        return failures
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-claude-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
