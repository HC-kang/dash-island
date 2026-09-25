import Foundation

/// Codex reset credits. Contract from openai/codex `backend-client`
/// (`rate_limit_resets.rs`) and the Codex TUI `/usage` flow.
extension CodexAdapter: LimitResetting {
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let resetConsumeURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!

    func limitResetOffer(_ ref: CredentialRef) async -> Result<LimitResetOffer, LimitResetFailure> {
        guard let creds = Self.readCredentials(codexHome: CredentialStore.directoryURL(for: ref)) else {
            return .failure(.unavailable)
        }
        var req = Self.resetRequest(url: Self.resetCreditsURL, token: creds.accessToken, accountID: creds.accountID)
        req.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse
        else { return .failure(.network) }
        if let failure = LimitResetFailure.from(status: http.statusCode) { return .failure(failure) }
        guard let count = Self.parseResetCredits(data) else { return .failure(.parse) }
        return .success(LimitResetOffer(available: count))
    }

    func useLimitReset(
        _ ref: CredentialRef,
        offer: LimitResetOffer,
        requestID: String
    ) async -> Result<LimitResetResult, LimitResetFailure> {
        guard let creds = Self.readCredentials(codexHome: CredentialStore.directoryURL(for: ref)) else {
            return .failure(.unavailable)
        }
        let req = Self.resetConsumeRequest(token: creds.accessToken, accountID: creds.accountID, requestID: requestID)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse
        else { return .failure(.network) }
        if let failure = LimitResetFailure.from(status: http.statusCode) { return .failure(failure) }
        guard let result = Self.parseResetConsume(data) else { return .failure(.parse) }
        return .success(result)
    }

    static func resetRequest(url: URL, token: String, accountID: String?) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return req
    }

    /// `POST …/consume` with `{"redeem_request_id": id}`. No `credit_id`: the
    /// backend spends the next available credit.
    static func resetConsumeRequest(token: String, accountID: String?, requestID: String) -> URLRequest {
        var req = resetRequest(url: resetConsumeURL, token: token, accountID: accountID)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["redeem_request_id": requestID])
        req.timeoutInterval = 15
        return req
    }

    /// `{"code": "reset" | "nothing_to_reset" | "no_credit" | "already_redeemed", …}`.
    /// An unknown code is nil: the caller treats the outcome as unknown.
    static func parseResetConsume(_ data: Data) -> LimitResetResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? String
        else { return nil }
        switch code {
        case "reset": return .reset(left: nil)
        case "already_redeemed": return .alreadyDone
        case "nothing_to_reset": return .notLimited
        case "no_credit": return .noCredit
        default: return nil
        }
    }
}
