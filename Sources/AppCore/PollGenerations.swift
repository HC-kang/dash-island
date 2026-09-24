import Foundation

// MARK: - Poll generations

/// Per-account counter bumped when an account's credentials change under a
/// running poll (reauth). A result is applied only when the generation it
/// started under is still current and the account still exists.
///
/// A hold covers a running Reauthenticate: the adapter moves the session
/// files aside, so a poll would read "no credentials". Held accounts are not
/// polled and take no result. Holds count, so overlapping reauths nest.
struct PollGenerations: Equatable {
    private var values: [AccountID: Int] = [:]
    private var holds: [AccountID: Int] = [:]

    func current(_ id: AccountID) -> Int { values[id] ?? 0 }

    mutating func bump(_ id: AccountID) { values[id] = current(id) + 1 }

    func isHeld(_ id: AccountID) -> Bool { (holds[id] ?? 0) > 0 }

    /// Drops results already in flight and stops new polls for `id`.
    mutating func hold(_ id: AccountID) {
        holds[id, default: 0] += 1
        bump(id)
    }

    mutating func release(_ id: AccountID) {
        let left = (holds[id] ?? 0) - 1
        holds[id] = left > 0 ? left : nil
    }

    func accepts(_ id: AccountID, generation: Int, live: Set<AccountID>) -> Bool {
        live.contains(id) && !isHeld(id) && current(id) == generation
    }

    mutating func prune(live: Set<AccountID>) {
        values = values.filter { live.contains($0.key) }
        holds = holds.filter { live.contains($0.key) }
    }
}

// MARK: - Per-account fetch status (status popover)

struct AccountFetchStatus: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case never
        case success
        case failure(String)
    }

    var id: AccountID
    var label: String
    var vendorID: VendorID
    /// When we last hit the vendor API for this account (ok or fail).
    var lastAttemptAt: Date?
    /// When we last got a clean snapshot.
    var lastSuccessAt: Date?
    /// Active cooldown end (429 / auth), if any.
    var cooldownUntil: Date? = nil
    /// Next scheduled attempt (cooldown or interval).
    var nextDueAt: Date? = nil
    var outcome: Outcome
}
