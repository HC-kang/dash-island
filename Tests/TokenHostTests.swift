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

        failures += await checkAsync("rotated tokens that fail to land on disk are not a success") {
            let fresh = #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":3600}"#
            let grok = try grokHome()
            let codex = try codexHome()
            defer {
                for dir in [grok, codex] {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                    try? FileManager.default.removeItem(at: dir)
                }
            }
            for dir in [grok, codex] {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            }
            let grokOutcome = await StubHTTP.with(status: 200, body: fresh) {
                await GrokAdapter.refreshManagedSession(grokHome: grok)
            }
            guard case .unavailable(let grokMessage, _) = grokOutcome else {
                throw TestFailure(description: "Grok: expected unavailable, got \(grokOutcome)")
            }
            try assertTrue(grokMessage.contains("credential write failed"))
            let codexOutcome = await StubHTTP.with(status: 200, body: fresh) {
                await CodexAdapter.refreshManagedCredentials(codexHome: codex, force: true)
            }
            guard case .unavailable(let codexMessage, _) = codexOutcome else {
                throw TestFailure(description: "Codex: expected unavailable, got \(codexOutcome)")
            }
            try assertTrue(codexMessage.contains("credential write failed"))
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
    typealias Answer = (status: Int, body: String, headers: [String: String])

    nonisolated(unsafe) static var route: ((URLRequest) -> Answer)?
    /// Requests answered since the last `with` began.
    nonisolated(unsafe) static var requestCount = 0
    /// Their URLs, in order.
    nonisolated(unsafe) static var requestURLs: [URL] = []

    static func with<T>(
        status: Int,
        body: String,
        headers: [String: String] = [:],
        _ run: () async -> T
    ) async -> T {
        await with(route: { _ in (status, body, headers) }, run)
    }

    /// One answer per request, e.g. by host or by `Authorization` header.
    static func with<T>(route: @escaping (URLRequest) -> Answer, _ run: () async -> T) async -> T {
        self.route = route
        requestCount = 0
        requestURLs = []
        URLProtocol.registerClass(StubHTTP.self)
        defer {
            URLProtocol.unregisterClass(StubHTTP.self)
            self.route = nil
        }
        return await run()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        if let url = request.url { Self.requestURLs.append(url) }
        guard let stub = Self.route?(request), let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
