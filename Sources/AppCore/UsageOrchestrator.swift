import Combine
import Foundation

/// Polls vendor adapters for each account, computes burn, and publishes
/// presentation-ready `[WidgetViewModel]` on the main actor.
///
/// Ponytail design: one object, one timer, parallel due-account fetches.
/// No priority queues or per-account interval UI.
@MainActor
final class UsageOrchestrator: ObservableObject {
    static let shared = UsageOrchestrator(
        accountStore: .shared,
        preferences: .shared
    )

    /// Default HTTP 429 cooldown when the snapshot does not supply `retryAfter`.
    nonisolated static let rateLimitCooldown: TimeInterval = 15 * 60

    @Published private(set) var widgets: [WidgetViewModel] = []
    @Published private(set) var loading = false
    @Published private(set) var lastUpdated: Date?

    private let accountStore: AccountStore
    private let preferences: PreferencesStore

    /// Last successful (error-free) snapshot per account — drives rings + burn.
    private var lastGood: [AccountID: UsageSnapshot] = [:]
    /// Previous good snapshot for burn Δ.
    private var prevGood: [AccountID: UsageSnapshot] = [:]
    /// Wall-clock of last fetch attempt (success or failure).
    private var lastFetchAt: [AccountID: Date] = [:]
    /// Soft / terminal error retained for captions.
    private var lastError: [AccountID: UsageError] = [:]
    /// Per-account 429 cooldown end times.
    private var cooldownUntil: [AccountID: Date] = [:]

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var polling = false

    init(accountStore: AccountStore, preferences: PreferencesStore) {
        self.accountStore = accountStore
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    /// Begin observing accounts/prefs and polling. Idempotent.
    func startAutoRefresh() {
        guard !started else {
            // Still kick a poll in case accounts loaded after a prior empty start.
            rebuildWidgets()
            Task { await pollDueAccounts() }
            return
        }
        started = true

        accountStore.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.onAccountsChanged()
            }
            .store(in: &cancellables)

        preferences.$pollSeconds
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rescheduleTimer()
            }
            .store(in: &cancellables)

        preferences.$displayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildWidgets()
            }
            .store(in: &cancellables)

        rescheduleTimer()
        rebuildWidgets()
        Task { await pollDueAccounts() }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        started = false
        polling = false
    }

    /// Force a poll. Optionally mark one account immediately due (e.g. after reauth).
    func refresh(accountID: AccountID? = nil) {
        if let accountID {
            lastFetchAt[accountID] = nil
            cooldownUntil[accountID] = nil
        }
        rebuildWidgets()
        Task { await pollDueAccounts() }
    }

    // MARK: - Due helper (pure, testable)

    /// Whether an account should be fetched at `now`.
    ///
    /// Due if never fetched, or `now - lastFetch >= max(userInterval, minPoll)`.
    nonisolated static func isDue(
        lastFetch: Date?,
        now: Date,
        userInterval: TimeInterval,
        minPoll: TimeInterval
    ) -> Bool {
        guard let lastFetch else { return true }
        let interval = max(userInterval, minPoll)
        guard interval > 0 else { return true }
        return now.timeIntervalSince(lastFetch) >= interval
    }

    // MARK: - Polling

    private func rescheduleTimer() {
        timer?.invalidate()
        let seconds = TimeInterval(preferences.pollSeconds)
        let t = Timer(timeInterval: max(1, seconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollDueAccounts()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func onAccountsChanged() {
        pruneState()
        rebuildWidgets()
        Task { await pollDueAccounts() }
    }

    private func pruneState() {
        let live = Set(accountStore.accounts.map(\.id))
        lastGood = lastGood.filter { live.contains($0.key) }
        prevGood = prevGood.filter { live.contains($0.key) }
        lastFetchAt = lastFetchAt.filter { live.contains($0.key) }
        lastError = lastError.filter { live.contains($0.key) }
        cooldownUntil = cooldownUntil.filter { live.contains($0.key) }
    }

    private func pollDueAccounts() async {
        // Coalesce overlapping ticks (timer may fire while a slow adapter runs).
        guard !polling else { return }
        polling = true
        loading = true
        defer {
            polling = false
            loading = false
        }

        let accounts = accountStore.accounts
        guard !accounts.isEmpty else {
            widgets = []
            return
        }

        let now = Date()
        let userInterval = TimeInterval(preferences.pollSeconds)

        var due: [Account] = []
        for account in accounts {
            if let until = cooldownUntil[account.id], now < until {
                continue
            }
            let minPoll = TimeInterval(
                VendorRegistry.adapter(for: account.vendorID)?.minPollSeconds ?? 300
            )
            if Self.isDue(
                lastFetch: lastFetchAt[account.id],
                now: now,
                userInterval: userInterval,
                minPoll: minPoll
            ) {
                due.append(account)
            }
        }

        guard !due.isEmpty else {
            rebuildWidgets()
            return
        }

        let results: [(AccountID, UsageSnapshot)] = await withTaskGroup(
            of: (AccountID, UsageSnapshot).self,
            returning: [(AccountID, UsageSnapshot)].self
        ) { group in
            for account in due {
                let ref = account.credentialRef
                let vendorID = account.vendorID
                let id = account.id
                group.addTask {
                    let snapshot: UsageSnapshot
                    if let adapter = VendorRegistry.adapter(for: vendorID) {
                        snapshot = await adapter.fetchUsage(ref)
                    } else {
                        snapshot = UsageSnapshot(
                            primary: WindowUsage(
                                usedFraction: 0,
                                resetAt: nil,
                                usedTokens: nil,
                                limitTokens: nil
                            ),
                            secondary: nil,
                            plan: nil,
                            fetchedAt: Date(),
                            error: .unavailable("unknown vendor")
                        )
                    }
                    return (id, snapshot)
                }
            }
            var collected: [(AccountID, UsageSnapshot)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        let applyAt = Date()
        var anyGood = false
        for (id, snapshot) in results {
            apply(accountID: id, snapshot: snapshot, now: applyAt)
            if snapshot.error == nil { anyGood = true }
        }
        if anyGood || lastUpdated == nil {
            lastUpdated = applyAt
        }
        rebuildWidgets()
    }

    private func apply(accountID: AccountID, snapshot: UsageSnapshot, now: Date) {
        lastFetchAt[accountID] = now

        if let error = snapshot.error {
            lastError[accountID] = error

            if case .rateLimited(let retryAfter) = error {
                cooldownUntil[accountID] = retryAfter
                    ?? now.addingTimeInterval(Self.rateLimitCooldown)
            }

            // Soft retention: keep last good rings when we already have them.
            // Auth terminal also keeps rings if present but always surfaces caption.
            if lastGood[accountID] == nil {
                // Cold start with only an error — still store so hover/caption work.
                lastGood[accountID] = snapshot
            }
            return
        }

        // Success: clear error + cooldown, advance burn samples.
        lastError[accountID] = nil
        cooldownUntil[accountID] = nil
        if let current = lastGood[accountID], current.error == nil {
            prevGood[accountID] = current
        }
        lastGood[accountID] = snapshot
    }

    // MARK: - View models

    private func rebuildWidgets() {
        let mode = preferences.displayMode
        widgets = accountStore.accounts.map { account in
            makeViewModel(account: account, mode: mode)
        }
    }

    private func makeViewModel(
        account: Account,
        mode: PreferencesStore.DisplayMode
    ) -> WidgetViewModel {
        let snap = lastGood[account.id]
        let prev = prevGood[account.id]
        let usedPrimary = snap?.primary.usedFraction ?? 0
        let usedSecondary = snap?.secondary?.usedFraction

        let primaryFraction = Self.displayFraction(used: usedPrimary, mode: mode)
        let secondaryFraction = usedSecondary.map {
            Self.displayFraction(used: $0, mode: mode)
        }

        let burn: BurnRate
        if let snap, snap.error == nil {
            burn = BurnRate.compute(
                prev: prev.map { ($0.primary.usedFraction, $0.fetchedAt) },
                current: (usedPrimary, snap.fetchedAt),
                resetAt: snap.primary.resetAt
            )
        } else {
            burn = BurnRate(ratio: 0, sampleCount: 1)
        }

        return WidgetViewModel(
            id: account.id,
            title: account.label,
            tint: Self.tint(for: account.vendorID),
            primaryFraction: primaryFraction,
            secondaryFraction: secondaryFraction,
            centerPercent: Int((primaryFraction * 100).rounded()),
            burnRatio: burn.ratio,
            hoverLines: Self.hoverLines(snapshot: snap, mode: mode),
            errorCaption: Self.caption(for: lastError[account.id] ?? snap?.error)
        )
    }

    /// Map used-fraction through display mode. Result always 0...1.
    nonisolated static func displayFraction(
        used: Double,
        mode: PreferencesStore.DisplayMode
    ) -> Double {
        let u = min(1, max(0, used))
        switch mode {
        case .used: return u
        case .remaining: return 1 - u
        }
    }

    nonisolated static func tint(for vendorID: VendorID) -> VendorTint {
        switch vendorID {
        case "claude": return .claude
        case "codex": return .codex
        case "grok": return .grok
        default: return .neutral
        }
    }

    nonisolated static func caption(for error: UsageError?) -> String? {
        guard let error else { return nil }
        switch error {
        case .authRequired:
            return "reauth required"
        case .rateLimited:
            return "rate limited"
        case .network(let message):
            return message.isEmpty ? "network error" : message
        case .parse(let message):
            return message.isEmpty ? "parse error" : message
        case .unavailable(let message):
            return message.isEmpty ? "unavailable" : message
        }
    }

    /// Hover tooltip lines. Absolute tokens in k/m when known; else percent.
    nonisolated static func hoverLines(
        snapshot: UsageSnapshot?,
        mode: PreferencesStore.DisplayMode
    ) -> [String] {
        guard let snapshot else { return [] }
        var lines: [String] = []
        lines.append(windowLine(label: "5h", window: snapshot.primary, mode: mode))
        if let secondary = snapshot.secondary {
            lines.append(windowLine(label: "wk", window: secondary, mode: mode))
        }
        return lines
    }

    nonisolated private static func windowLine(
        label: String,
        window: WindowUsage,
        mode: PreferencesStore.DisplayMode
    ) -> String {
        if let used = window.usedTokens, let limit = window.limitTokens, limit > 0 {
            return "\(label)  \(formatTokens(used)) / \(formatTokens(limit))"
        }
        let fraction = displayFraction(used: window.usedFraction, mode: mode)
        let pct = Int((fraction * 100).rounded())
        return "\(label)  \(pct)%"
    }

    /// Compact token count for hover (k / m).
    nonisolated static func formatTokens(_ n: Int64) -> String {
        let v = Double(n)
        if n < 1_000 {
            return "\(n)"
        }
        if n < 10_000 {
            return String(format: "%.1fk", v / 1_000)
        }
        if n < 1_000_000 {
            return String(format: "%.0fk", v / 1_000)
        }
        if n < 10_000_000 {
            return String(format: "%.1fm", v / 1_000_000)
        }
        return String(format: "%.0fm", v / 1_000_000)
    }
}
