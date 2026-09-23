import Foundation

enum TokenHostSuite {
    static func run() async -> Int {
        print("TokenHostSuite")
        var failures = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func body(_ s: String) -> Data { Data(s.utf8) }

        failures += check("token host 429 and 5xx are soft, with a capped retry") {
            try assertEqual(
                TokenHostFailure.classify(status: 429, body: Data(), retryAfter: "120", now: now),
                .unavailable(retryAt: now.addingTimeInterval(120))
            )
            try assertEqual(
                TokenHostFailure.classify(status: 429, body: Data(), retryAfter: "86400", now: now),
                .unavailable(retryAt: now.addingTimeInterval(TokenHostFailure.maxQuiet))
            )
            try assertEqual(
                TokenHostFailure.classify(status: 429, body: body("invalid_grant"), retryAfter: nil, now: now),
                .unavailable(retryAt: now.addingTimeInterval(TokenHostFailure.maxQuiet))
            )
            try assertEqual(
                TokenHostFailure.classify(status: 503, body: Data(), retryAfter: nil, now: now),
                .unavailable(retryAt: nil)
            )
            try assertEqual(
                TokenHostFailure.classify(status: 400, body: body("<html>not found</html>"), retryAfter: nil),
                .unavailable(retryAt: nil)
            )
        }

        failures += check("only a spent or revoked grant is rejected") {
            try assertEqual(
                TokenHostFailure.classify(status: 400, body: body(#"{"error":"invalid_grant"}"#), retryAfter: nil),
                .rejected
            )
            try assertEqual(
                TokenHostFailure.classify(
                    status: 401,
                    body: body(#"{"error":{"code":"refresh_token_reused"}}"#),
                    retryAfter: nil
                ),
                .rejected
            )
            try assertEqual(
                TokenHostFailure.classify(status: 401, body: body(#"{"error":"invalid_client"}"#), retryAfter: nil),
                .badClient
            )
        }

        failures += check("quiet snapshot stays soft and carries the retry time") {
            let retry = now.addingTimeInterval(600)
            for status in [nil, 429, 503] as [Int?] {
                let snap = TokenHostFailure.quietSnapshot(
                    message: TokenHostFailure.quietMessage(status: status),
                    retryAt: retry,
                    fetchedAt: now
                )
                guard let error = snap.error else { throw TestFailure(description: "no error") }
                try assertEqual(UsageSnapshotMerge.failureKind(error), .soft)
                try assertEqual(UsageOrchestrator.caption(for: error, vendorID: "grok"), "token quiet")
                try assertEqual(snap.retryAt, retry)
            }
        }

        failures += await checkAsync("Grok token host 429 is a soft quiet, not a usage 429") {
            let home = try grokHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let outcome = await StubHTTP.with(status: 429, body: "", headers: ["Retry-After": "60"]) {
                await GrokAdapter.refreshManagedSession(grokHome: home)
            }
            guard case .unavailable(let message, let retryAt) = outcome else {
                throw TestFailure(description: "expected soft unavailable, got \(outcome)")
            }
            try assertTrue(message.contains("token quiet"))
            try assertTrue(retryAt != nil, "429 carries a retry time")
        }

        failures += await checkAsync("Grok 401 without invalid_grant keeps the session") {
            let home = try grokHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let outcome = await StubHTTP.with(status: 401, body: "<html>edge</html>") {
                await GrokAdapter.refreshManagedSession(grokHome: home)
            }
            guard case .unavailable = outcome else {
                throw TestFailure(description: "expected soft unavailable, got \(outcome)")
            }
            let dead = await StubHTTP.with(status: 400, body: #"{"error":"invalid_grant"}"#) {
                await GrokAdapter.refreshManagedSession(grokHome: home)
            }
            try assertEqual(dead, .rejected)
        }

        failures += await checkAsync("Codex forced refresh on a busy token host is soft, not reconnect") {
            let home = try codexHome()
            defer { try? FileManager.default.removeItem(at: home) }
            for status in [429, 502] {
                let outcome = await StubHTTP.with(status: status, body: "") {
                    await CodexAdapter.refreshManagedCredentials(codexHome: home, force: true)
                }
                guard case .unavailable = outcome else {
                    throw TestFailure(description: "HTTP \(status): expected soft unavailable, got \(outcome)")
                }
            }
            let dead = await StubHTTP.with(status: 401, body: #"{"error":{"code":"refresh_token_expired"}}"#) {
                await CodexAdapter.refreshManagedCredentials(codexHome: home, force: true)
            }
            try assertEqual(dead, .rejected)
        }

        return failures
    }

    private static func tempHome(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func grokHome() throws -> URL {
        let home = try tempHome("grok")
        let auth = #"{"https://auth.x.ai::client-1":{"key":"tok","refresh_token":"rt","expires_at":"2020-01-01T00:00:00Z"}}"#
        try Data(auth.utf8).write(to: home.appendingPathComponent("auth.json"))
        return home
    }

    private static func codexHome() throws -> URL {
        let home = try tempHome("codex")
        let auth = #"{"tokens":{"access_token":"at","refresh_token":"rt"}}"#
        try Data(auth.utf8).write(to: home.appendingPathComponent("auth.json"))
        return home
    }
}

/// Answers every `URLSession.shared` request in-process; tests never reach a vendor.
final class StubHTTP: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data, headers: [String: String])?

    static func with<T>(
        status: Int,
        body: String,
        headers: [String: String] = [:],
        _ run: () async -> T
    ) async -> T {
        response = (status, Data(body.utf8), headers)
        URLProtocol.registerClass(StubHTTP.self)
        defer {
            URLProtocol.unregisterClass(StubHTTP.self)
            response = nil
        }
        return await run()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.response, let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
