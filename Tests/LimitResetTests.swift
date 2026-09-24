import Foundation

/// Reset credits: request shapes and answer parsing against the vendor
/// contracts. No test sends a request; a real call spends a credit.
enum LimitResetSuite {
    static func run() -> Int {
        print("LimitResetSuite")
        var failures = 0

        func body(_ req: URLRequest) throws -> [String: String] {
            guard let data = req.httpBody,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
            else { throw TestFailure(description: "request body is not a string map") }
            return obj
        }

        failures += check("codex consume: POST, account headers, idempotency key only") {
            let req = CodexAdapter.resetConsumeRequest(token: "tok", accountID: "acct-1", requestID: "req-1")
            try assertEqual(req.httpMethod, "POST")
            try assertEqual(req.url?.absoluteString, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")
            try assertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            try assertEqual(req.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
            try assertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            try assertEqual(try body(req), ["redeem_request_id": "req-1"])
        }

        failures += check("codex consume: every documented code, unknown is nil") {
            func parse(_ code: String) -> LimitResetResult? {
                CodexAdapter.parseResetConsume(Data(#"{"code":"\#(code)","windows_reset":2}"#.utf8))
            }
            try assertEqual(parse("reset"), .reset(left: nil))
            try assertEqual(parse("already_redeemed"), .alreadyDone)
            try assertEqual(parse("nothing_to_reset"), .notLimited)
            try assertEqual(parse("no_credit"), .noCredit)
            try assertTrue(parse("something_new") == nil)
            try assertTrue(CodexAdapter.parseResetConsume(Data("{}".utf8)) == nil)
        }

        failures += check("claude reset: POST to the org, cedar_ember body") {
            let req = ClaudeAdapter.limitResetRequest(
                token: "tok", organizationID: "0000aaaa-11bb-22cc-33dd-444444eeeeee",
                grantID: "grant_1", requestID: "req-1"
            )
            try assertEqual(req?.httpMethod, "POST")
            try assertEqual(req?.url?.absoluteString,
                            "https://api.anthropic.com/api/organizations/0000aaaa-11bb-22cc-33dd-444444eeeeee/reset_rate_limits")
            try assertEqual(req?.value(forHTTPHeaderField: "anthropic-beta"), ClaudeAdapter.betaHeader)
            try assertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            try assertEqual(try body(req!), ["program": "cedar_ember", "grant_id": "grant_1", "request_id": "req-1"])
        }

        failures += check("claude reset: ids outside the vendor format build no request") {
            func build(org: String = "org-1", grant: String = "g1", request: String = "r1") -> URLRequest? {
                ClaudeAdapter.limitResetRequest(token: "t", organizationID: org, grantID: grant, requestID: request)
            }
            try assertTrue(build() != nil)
            try assertTrue(build(org: "../users") == nil)
            try assertTrue(build(org: "") == nil)
            try assertTrue(build(grant: "Grant") == nil)
            try assertTrue(build(grant: String(repeating: "a", count: 41)) == nil)
            try assertTrue(build(request: "has space") == nil)
        }

        let offerJSON = """
        {"five_hour": {"utilization": 100},
         "cedar_ember": {"eligible": true, "at_limit": %@, "next_grant_id": "g2",
           "grants": [
             {"id": "g1", "resets_left": 0, "clears": ["five_hour"]},
             {"id": "g2", "resets_left": 2, "clears": ["five_hour", "seven_day"], "usable_now": %@,
              "use_requires_limit": true, "ends_at": "2026-10-22T00:00:00Z"}
           ]}}
        """
        func offer(atLimit: Bool) -> LimitResetOffer? {
            let json = String(format: offerJSON, atLimit ? "true" : "false", atLimit ? "true" : "false")
            return ClaudeAdapter.parseLimitResetOffer(Data(json.utf8))
        }

        failures += check("claude offer: sums grants, targets next_grant_id") {
            let o = offer(atLimit: true)
            try assertEqual(o?.available, 2)
            try assertEqual(o?.grantID, "g2")
            try assertEqual(o?.clears ?? [], ["five_hour", "seven_day"])
            try assertEqual(o?.expiresAt?.timeIntervalSince1970 ?? -1, 1_792_627_200, accuracy: 0.5)
            try assertTrue(o?.canUse == true)
        }

        failures += check("claude offer: a limit-only grant waits for a full limit") {
            let o = offer(atLimit: false)
            try assertTrue(o?.ineligibleReason == nil)
            try assertTrue(o?.canUse == false)
        }

        failures += check("claude offer: ineligible, paused, missing block") {
            let off = ClaudeAdapter.parseLimitResetOffer(Data(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"tier"}}"#.utf8))
            try assertEqual(off?.ineligibleReason, "tier")
            try assertTrue(off?.canUse == false)
            let paused = ClaudeAdapter.parseLimitResetOffer(Data(#"""
            {"cedar_ember":{"eligible":true,"at_limit":true,"next_grant_id":"g","grants":[{"id":"g","resets_left":1,"paused":true}]}}
            """#.utf8))
            try assertEqual(paused?.ineligibleReason, "paused")
            try assertTrue(ClaudeAdapter.parseLimitResetOffer(Data(#"{"five_hour":{}}"#.utf8)) == nil)
        }

        failures += check("claude result: documented results, unknown is nil") {
            func parse(_ json: String) -> LimitResetResult? { ClaudeAdapter.parseLimitResetResult(Data(json.utf8)) }
            try assertEqual(parse(#"{"result":"reset","resets_left":1,"cleared":["five_hour"]}"#), .reset(left: 1))
            try assertEqual(parse(#"{"result":"already_used"}"#), .alreadyDone)
            try assertEqual(parse(#"{"result":"not_limited"}"#), .notLimited)
            try assertEqual(parse(#"{"result":"cooldown","reason":"cooldown"}"#), .refused(reason: "cooldown"))
            try assertEqual(parse(#"{"result":"ineligible"}"#), .refused(reason: "ineligible"))
            try assertTrue(parse(#"{"result":"brand_new"}"#) == nil)
        }

        failures += check("request id survives only an unknown outcome") {
            typealias R = Result<LimitResetResult, LimitResetFailure>
            let keep: [R] = [.failure(.network), .failure(.http(502)), .failure(.parse)]
            let drop: [R] = [.success(.reset(left: 0)), .success(.alreadyDone), .success(.notLimited),
                             .success(.noCredit), .failure(.authRequired), .failure(.rateLimited), .failure(.unavailable)]
            for r in keep { try assertTrue(LimitResetCenter.keepsRequestID(after: r), "keep \(r)") }
            for r in drop { try assertTrue(!LimitResetCenter.keepsRequestID(after: r), "drop \(r)") }
        }

        failures += check("only reset and alreadyDone count as spent") {
            try assertTrue(LimitResetCenter.spent(.reset(left: nil)))
            try assertTrue(LimitResetCenter.spent(.alreadyDone))
            try assertTrue(!LimitResetCenter.spent(.notLimited))
            try assertTrue(!LimitResetCenter.spent(.noCredit))
            try assertTrue(!LimitResetCenter.spent(.refused(reason: "x")))
        }

        failures += check("status mapping: 2xx none, auth, 429, other") {
            try assertTrue(LimitResetFailure.from(status: 200) == nil)
            try assertEqual(LimitResetFailure.from(status: 401), .authRequired)
            try assertEqual(LimitResetFailure.from(status: 403), .authRequired)
            try assertEqual(LimitResetFailure.from(status: 429), .rateLimited)
            try assertEqual(LimitResetFailure.from(status: 500), .http(500))
        }

        failures += check("organization id comes from .claude.json oauthAccount") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reset-org-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try assertTrue(ClaudeAdapter.organizationID(configDir: dir) == nil)
            try Data(#"{"oauthAccount":{"organizationUuid":"org-9"}}"#.utf8)
                .write(to: dir.appendingPathComponent(".claude.json"))
            try assertEqual(ClaudeAdapter.organizationID(configDir: dir), "org-9")
        }
        return failures
    }
}
