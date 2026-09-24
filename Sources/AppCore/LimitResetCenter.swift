import Foundation

/// Reads and spends vendor reset credits for the detail panel.
///
/// A spent credit cannot come back, so:
/// - one request per account at a time;
/// - an attempt with an unknown outcome (timeout, 5xx) keeps its request id,
///   and the next attempt reuses it (the vendor's idempotency key);
/// - after a definite answer the id is dropped and usage refreshes.
@MainActor
final class LimitResetCenter: ObservableObject {
    static let shared = LimitResetCenter()

    enum OfferState: Equatable {
        case loading
        case ready(LimitResetOffer)
        case unavailable
    }

    @Published private(set) var offers: [AccountID: OfferState] = [:]
    @Published private(set) var inFlight: Set<AccountID> = []
    /// Last outcome line per account, shown under the reset row.
    @Published private(set) var notes: [AccountID: String] = [:]

    private var loadedAt: [AccountID: Date] = [:]
    /// Request id of an attempt whose outcome is unknown.
    /// ponytail: memory only; an app quit loses it. Persist if that bites.
    private var pendingRequestID: [AccountID: String] = [:]
    private static let reloadGap: TimeInterval = 60

    nonisolated static func resetter(for vendorID: VendorID) -> (any LimitResetting)? {
        VendorRegistry.adapter(for: vendorID) as? any LimitResetting
    }

    /// Loads the offer at most once a minute per account (the panel reloads often).
    func load(_ account: Account, force: Bool = false) {
        guard let resetter = Self.resetter(for: account.vendorID) else { return }
        let id = account.id
        if !force, let at = loadedAt[id], Date().timeIntervalSince(at) < Self.reloadGap { return }
        loadedAt[id] = Date()
        if offers[id] == nil { offers[id] = .loading }
        Task {
            let result = await resetter.limitResetOffer(account.credentialRef)
            switch result {
            case .success(let offer):
                Log.accounts.info("reset offer account=\(id.short) available=\(offer.available) reason=\(offer.ineligibleReason ?? "-") requires_limit=\(offer.requiresLimit) at_limit=\(offer.atLimit.map(String.init) ?? "-") clears=\(offer.clears.joined(separator: ","))")
                offers[id] = .ready(offer)
            case .failure(let failure):
                Log.accounts.info("reset offer account=\(id.short) outcome=\(failure)")
                offers[id] = .unavailable
            }
        }
    }

    /// Spends one credit. The caller has already asked the user to confirm.
    func use(_ account: Account, offer: LimitResetOffer) {
        guard let resetter = Self.resetter(for: account.vendorID), !inFlight.contains(account.id) else { return }
        let id = account.id
        let requestID = pendingRequestID[id] ?? UUID().uuidString
        pendingRequestID[id] = requestID
        inFlight.insert(id)
        notes[id] = nil
        Task {
            let result = await resetter.useLimitReset(account.credentialRef, offer: offer, requestID: requestID)
            inFlight.remove(id)
            if !Self.keepsRequestID(after: result) { pendingRequestID[id] = nil }
            switch result {
            case .success(let answer):
                Log.accounts.info("reset use account=\(id.short) outcome=\(Self.logName(answer))")
                notes[id] = Self.note(for: answer)
                if Self.spent(answer) { UsageOrchestrator.shared.refresh(accountID: id) }
            case .failure(let failure):
                Log.accounts.warn("reset use account=\(id.short) outcome=\(failure) unknown=\(failure.outcomeUnknown)")
                notes[id] = Self.note(for: failure)
            }
            load(account, force: true)
        }
    }

    /// Keep the id only while the vendor may have spent the credit without
    /// telling us; the retry then replays the same attempt.
    nonisolated static func keepsRequestID(after result: Result<LimitResetResult, LimitResetFailure>) -> Bool {
        if case .failure(let failure) = result { return failure.outcomeUnknown }
        return false
    }

    nonisolated static func spent(_ result: LimitResetResult) -> Bool {
        switch result {
        case .reset, .alreadyDone: return true
        case .notLimited, .noCredit, .refused: return false
        }
    }

    nonisolated static func note(for result: LimitResetResult) -> String {
        switch result {
        case .reset(let left?):
            return String(localized: "Limits reset. \(left) left.")
        case .reset(nil), .alreadyDone:
            return String(localized: "Limits reset.")
        case .notLimited:
            return String(localized: "No limit needs a reset now. Nothing was used.")
        case .noCredit:
            return String(localized: "No reset is available. Nothing was used.")
        case .refused(let reason):
            return String(localized: "The vendor refused the reset (\(reason)). Nothing was used.")
        }
    }

    nonisolated static func note(for failure: LimitResetFailure) -> String {
        switch failure {
        case .authRequired:
            return String(localized: "Sign-in expired. Nothing was used. Try again after the next update.")
        case .rateLimited:
            return String(localized: "Too many requests. Nothing was used. Try again later.")
        case .unavailable:
            return String(localized: "Resets are not available for this account now. Nothing was used.")
        case .network, .http, .parse:
            return String(localized: "No answer from the vendor. Try again: the retry cannot spend a second reset.")
        }
    }

    private nonisolated static func logName(_ result: LimitResetResult) -> String {
        switch result {
        case .reset: return "reset"
        case .alreadyDone: return "already_done"
        case .notLimited: return "not_limited"
        case .noCredit: return "no_credit"
        case .refused: return "refused"
        }
    }
}
