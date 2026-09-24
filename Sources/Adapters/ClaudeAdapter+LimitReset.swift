import Foundation

/// Claude limit resets (Anthropic "limit reset", Claude Code `/limit-reset`,
/// program `cedar_ember`). Contract read from the Claude Code 2.1.281 bundle
/// and support.claude.com/en/articles/17007452.
extension ClaudeAdapter: LimitResetting {
    /// Same endpoint as the poll; the query adds the `cedar_ember` block.
    static let limitResetOfferURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!

    func limitResetOffer(_ ref: CredentialRef) async -> Result<LimitResetOffer, LimitResetFailure> {
        let dir = CredentialStore.directoryURL(for: ref)
        guard Self.pingPendingSnapshot(configDir: dir) == nil,
              let creds = Self.readCredentials(configDir: dir)
        else { return .failure(.unavailable) }
        var req = Self.oauthRequest(url: Self.limitResetOfferURL, token: creds.accessToken)
        req.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse
        else { return .failure(.network) }
        if let failure = LimitResetFailure.from(status: http.statusCode) { return .failure(failure) }
        guard let offer = Self.parseLimitResetOffer(data) else { return .failure(.parse) }
        return .success(offer)
    }

    func useLimitReset(
        _ ref: CredentialRef,
        offer: LimitResetOffer,
        requestID: String
    ) async -> Result<LimitResetResult, LimitResetFailure> {
        let dir = CredentialStore.directoryURL(for: ref)
        guard Self.pingPendingSnapshot(configDir: dir) == nil,
              let creds = Self.readCredentials(configDir: dir),
              let org = Self.organizationID(configDir: dir),
              let grantID = offer.grantID,
              let req = Self.limitResetRequest(token: creds.accessToken, organizationID: org,
                                               grantID: grantID, requestID: requestID)
        else { return .failure(.unavailable) }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse
        else { return .failure(.network) }
        if let failure = LimitResetFailure.from(status: http.statusCode) { return .failure(failure) }
        guard let result = Self.parseLimitResetResult(data) else { return .failure(.parse) }
        return .success(result)
    }

    static func oauthRequest(url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The reset program is gated on the client surface, read from this
        // header: the CLI sends `claude-cli/<ver> (external, cli)` here, and
        // `claude-code/…` answers `ineligible_reason: surface`.
        req.setValue(resetUserAgent(), forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Fallback when no CLI install is found; the vendor may also gate on version.
    static let resetFallbackCLIVersion = "2.1.281"

    static func resetUserAgent(versionsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/claude/versions", isDirectory: true)) -> String {
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path)) ?? []
        return "claude-cli/\(newestVersion(installed) ?? resetFallbackCLIVersion) (external, cli)"
    }

    /// Highest `x.y.z` among directory names; other names are ignored.
    static func newestVersion(_ names: [String]) -> String? {
        func parts(_ name: String) -> [Int]? {
            let p = name.split(separator: ".").compactMap { Int($0) }
            return p.count == 3 && name.split(separator: ".").count == 3 ? p : nil
        }
        return names.filter { parts($0) != nil }.max { parts($0)!.lexicographicallyPrecedes(parts($1)!) }
    }

    /// `POST /api/organizations/{org}/reset_rate_limits`. Nil when an id does
    /// not match the vendor's format (it would also land in the URL path).
    static func limitResetRequest(
        token: String,
        organizationID: String,
        grantID: String,
        requestID: String
    ) -> URLRequest? {
        guard organizationID.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
              grantID.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil,
              requestID.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.anthropic.com/api/organizations/\(organizationID)/reset_rate_limits")
        else { return nil }
        var req = oauthRequest(url: url, token: token)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "program": "cedar_ember", "grant_id": grantID, "request_id": requestID,
        ])
        req.timeoutInterval = 25
        return req
    }

    /// `oauthAccount.organizationUuid` in the folder's `.claude.json` (the CLI
    /// writes it at login). Not a credential file.
    static func organizationID(configDir: URL) -> String? {
        let url = configDir.appendingPathComponent(".claude.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any],
              let org = account["organizationUuid"] as? String, !org.isEmpty
        else { return nil }
        return org
    }

    /// The `cedar_ember` block of `/api/oauth/usage?cedar_ember=1`. Nil when the
    /// block is missing (feature off for this account or this client).
    static func parseLimitResetOffer(_ data: Data) -> LimitResetOffer? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = obj["cedar_ember"] as? [String: Any]
        else { return nil }
        if (block["eligible"] as? Bool) == false {
            return LimitResetOffer(available: 0, ineligibleReason: block["ineligible_reason"] as? String ?? "unknown")
        }
        let grants = block["grants"] as? [[String: Any]] ?? []
        var offer = LimitResetOffer(
            available: grants.compactMap { ($0["resets_left"] as? NSNumber)?.intValue }.filter { $0 > 0 }.reduce(0, +)
        )
        offer.atLimit = block["at_limit"] as? Bool
        guard let nextID = block["next_grant_id"] as? String,
              let next = grants.first(where: { $0["id"] as? String == nextID })
        else {
            if offer.available > 0 { offer.ineligibleReason = "no_grant" }
            return offer
        }
        offer.grantID = nextID
        offer.requiresLimit = next["use_requires_limit"] as? Bool ?? true
        offer.clears = next["clears"] as? [String] ?? []
        offer.expiresAt = parseDate(next["ends_at"])
        if (next["paused"] as? Bool) == true {
            offer.ineligibleReason = "paused"
        } else if (next["usable_now"] as? Bool) == false, !(offer.requiresLimit && offer.atLimit == false) {
            offer.ineligibleReason = "not_usable_now"
        }
        return offer
    }

    /// `{"result": "reset" | "already_used" | "not_limited" | "cooldown" | "ineligible" | "unavailable", …}`.
    /// An unknown result is nil: the caller treats the outcome as unknown.
    static func parseLimitResetResult(_ data: Data) -> LimitResetResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? String
        else { return nil }
        switch result {
        case "reset": return .reset(left: (obj["resets_left"] as? NSNumber)?.intValue)
        case "already_used": return .alreadyDone
        case "not_limited": return .notLimited
        case "cooldown", "ineligible", "unavailable":
            return .refused(reason: obj["reason"] as? String ?? result)
        default: return nil
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let text = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }
}
