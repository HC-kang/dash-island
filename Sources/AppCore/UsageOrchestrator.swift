import AppKit
import Combine
import Foundation

/// Polls vendor adapters for each account, computes burn, and publishes
/// presentation-ready `[WidgetViewModel]` on the main actor.
///
/// **Rate-limit philosophy** (Claude-first):
/// - Background: fixed 15m seed (no user interval picker).
/// - Expand: lazy refresh after dwell, debounced by max(120s, vendor minPoll).
/// - Prefer last-good snapshot over aggressive 429.
/// - Sleep: no network; lock: floor 30m; launch: one seed poll.
@MainActor
final class UsageOrchestrator: ObservableObject {
    static let shared = UsageOrchestrator(
        accountStore: .shared,
        preferences: .shared
    )

    /// Fixed background cadence (Orca-aligned, Claude-friendly).
    nonisolated static let backgroundPollSeconds: TimeInterval = 15 * 60
    /// Expand/lazy floor — never more often than this even if minPoll is lower.
    nonisolated static let expandDebounceFloor: TimeInterval = 120
    /// Max concurrent vendor HTTP fetches (multi-account spike control).
    nonisolated static let maxFetchConcurrency = 2
    /// Default HTTP 429 cooldown when the snapshot does not supply `retryAfter`.
    nonisolated static let rateLimitCooldown: TimeInterval = 30 * 60
    /// After auth failure, back off so we do not 401-spam overnight.
    nonisolated static let authFailureCooldown: TimeInterval = 30 * 60
    /// While the Mac is asleep / screen locked, floor poll spacing.
    nonisolated static let inactivePollFloor: TimeInterval = 30 * 60

    enum PollMode: Equatable, Sendable {
        /// Timer / wake: `backgroundPollSeconds` × minPoll.
        case background
        /// Island expanded (after dwell): fresher, but still minPoll-floor.
        case expand
        /// Manual refresh — still respects minPoll unless cooldowns cleared by `refresh()`.
        case force
    }

    @Published private(set) var widgets: [WidgetViewModel] = []
    @Published private(set) var loading = false
    @Published private(set) var lastUpdated: Date?
    /// Per-account last request outcome (status popover).
    @Published private(set) var fetchStatuses: [AccountFetchStatus] = []
    /// Rough request budget line for status UI.
    @Published private(set) var budgetCaption: String = ""

    private let accountStore: AccountStore
    private let preferences: PreferencesStore

    /// Last successful (error-free) snapshot per account — drives rings + burn.
    private var lastGood: [AccountID: UsageSnapshot] = [:]
    /// Per-account EWMA burn smoother (sample ring + smoothed needle ratio).
    private var burnByAccount: [AccountID: BurnSmoother] = [:]
    /// Per-account needle signal provenance.
    private var burnSourceByAccount: [AccountID: BurnSignalSource] = [:]
    /// Wall-clock of last fetch attempt (success or failure).
    private var lastFetchAt: [AccountID: Date] = [:]
    /// Wall-clock of last **successful** fetch per account.
    private var lastSuccessAt: [AccountID: Date] = [:]
    /// Soft / terminal error retained for captions.
    private var lastError: [AccountID: UsageError] = [:]
    /// Per-account 429 / auth cooldown end times.
    private var cooldownUntil: [AccountID: Date] = [:]
    /// Soft notices (token expiring soon).
    private var lastNotice: [AccountID: String] = [:]

    private var timer: Timer?
    /// Local-only Claude needle tick (no network).
    private var burnTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var powerObservers: [NSObjectProtocol] = []
    private var started = false
    private var polling = false
    /// True between willSleep and didWake — skip network polls.
    private var systemAsleep = false
    /// Screen locked (optional extra inactive floor when awake).
    private var screenLocked = false

    /// How often to re-read local Claude session logs for the needle.
    nonisolated static let localBurnSeconds: TimeInterval = 60

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
            Task { await pollDueAccounts(mode: .background, forceActive: true) }
            return
        }
        started = true

        accountStore.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Always rebuild so reorder (same set, new order) is reflected.
                self?.onAccountsChanged()
            }
            .store(in: &cancellables)

        preferences.$displayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildWidgets()
            }
            .store(in: &cancellables)

        installPowerObservers()
        rescheduleTimer()
        rescheduleBurnTimer()
        rebuildWidgets()
        // Launch seed — one background pass so rings aren't empty.
        Task { await pollDueAccounts(mode: .background, forceActive: true) }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        burnTimer?.invalidate()
        burnTimer = nil
        let wsnc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        for token in powerObservers {
            wsnc.removeObserver(token)
            dnc.removeObserver(token)
        }
        powerObservers.removeAll()
        cancellables.removeAll()
        started = false
        polling = false
    }

    /// Force a poll. Optionally mark one account immediately due (e.g. after reauth).
    /// Clears cooldown for the target account (or all when nil).
    func refresh(accountID: AccountID? = nil) {
        if let accountID {
            lastFetchAt[accountID] = nil
            cooldownUntil[accountID] = nil
        } else {
            for id in accountStore.accounts.map(\.id) {
                lastFetchAt[id] = nil
                cooldownUntil[id] = nil
            }
        }
        rebuildWidgets()
        Task { await pollDueAccounts(mode: .force, forceActive: true) }
    }

    /// Island became expanded (caller should dwell ~400ms first). Lazy refresh
    /// stale accounts without clearing 429/auth cooldowns.
    func onIslandExpanded() {
        Task { await pollDueAccounts(mode: .expand, forceActive: true) }
    }

    private func installPowerObservers() {
        let wsnc = NSWorkspace.shared.notificationCenter
        powerObservers.append(
            wsnc.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.systemAsleep = true }
            }
        )
        powerObservers.append(
            wsnc.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.systemAsleep = false
                    await self?.pollDueAccounts(mode: .background, forceActive: true)
                }
            }
        )
        let dnc = DistributedNotificationCenter.default()
        powerObservers.append(
            dnc.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenLocked = true }
            }
        )
        powerObservers.append(
            dnc.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenLocked = false }
            }
        )
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

    /// Interval used for expand lazy-refresh: never below `expandDebounceFloor`
    /// or the vendor's `minPollSeconds`.
    nonisolated static func expandInterval(minPoll: TimeInterval) -> TimeInterval {
        max(expandDebounceFloor, minPoll)
    }

    // MARK: - Polling

    private func rescheduleTimer() {
        timer?.invalidate()
        let seconds = Self.backgroundPollSeconds
        let t = Timer(timeInterval: max(1, seconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollDueAccounts(mode: .background)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func rescheduleBurnTimer() {
        burnTimer?.invalidate()
        let t = Timer(timeInterval: Self.localBurnSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleLocalBurnActivity()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        burnTimer = t
    }

    private func onAccountsChanged() {
        pruneState()
        rebuildWidgets()
        Task { await pollDueAccounts(mode: .background, forceActive: true) }
    }

    /// **No network.** Refresh Claude needles from local session logs only.
    private func sampleLocalBurnActivity() {
        guard !polling, !systemAsleep else { return }
        guard accountStore.accounts.contains(where: { $0.vendorID == "claude" }) else { return }

        let now = Date()
        let claudeActivity = ClaudeActivity.liveBurnRatio(now: now)
        guard claudeActivity > 0 else { return }

        var changed = false
        for account in accountStore.accounts where account.vendorID == "claude" {
            var smoother = burnByAccount[account.id] ?? BurnSmoother()
            let before = smoother.current.ratio
            _ = smoother.noteLiveActivity(ratio: claudeActivity, at: now)
            burnByAccount[account.id] = smoother
            mergeBurnSource(accountID: account.id, local: true)
            if abs(smoother.current.ratio - before) > 1e-6 { changed = true }
        }
        if changed { rebuildWidgets() }
    }

    private func mergeBurnSource(accountID: AccountID, api: Bool = false, local: Bool = false) {
        let prev = burnSourceByAccount[accountID] ?? .none
        var hasAPI = (prev == .api || prev == .both)
        var hasLocal = (prev == .local || prev == .both)
        if api { hasAPI = true }
        if local { hasLocal = true }
        switch (hasAPI, hasLocal) {
        case (true, true): burnSourceByAccount[accountID] = .both
        case (true, false): burnSourceByAccount[accountID] = .api
        case (false, true): burnSourceByAccount[accountID] = .local
        case (false, false): burnSourceByAccount[accountID] = BurnSignalSource.none
        }
    }

    private func pushBurn(accountID: AccountID, snapshot: UsageSnapshot) {
        let burnWin = snapshot.preferredBurnWindow
        // Observation time = now (not fetch-start). Micro-polls 60s apart need real Δt.
        let observedAt = Date()
        var smoother = burnByAccount[accountID] ?? BurnSmoother()
        let before = smoother.current.ratio
        let result = smoother.push(
            BurnSample(
                usedFraction: burnWin.usedFraction,
                at: observedAt,
                resetAt: burnWin.resetAt,
                kind: burnWin.kind,
                usedTokens: burnWin.usedTokens,
                limitTokens: burnWin.limitTokens
            )
        )
        burnByAccount[accountID] = smoother
        // Positive API-derived movement (ratio rose from a sample Δ).
        if result.ratio > before + 0.02 || (before < 0.03 && result.ratio > 0.05) {
            mergeBurnSource(accountID: accountID, api: true)
        }
        NSLog(
            "DashIsland: burn account=%@ kind=%@ u=%.4f abs=%@ ratio=%.3f samples=%d",
            String(accountID.uuidString.prefix(8)),
            burnWin.kind.rawValue,
            burnWin.usedFraction,
            burnWin.hasAbsoluteCounters ? "y" : "n",
            result.ratio,
            result.sampleCount
        )
    }

    private func pruneState() {
        let live = Set(accountStore.accounts.map(\.id))
        lastGood = lastGood.filter { live.contains($0.key) }
        burnByAccount = burnByAccount.filter { live.contains($0.key) }
        burnSourceByAccount = burnSourceByAccount.filter { live.contains($0.key) }
        lastFetchAt = lastFetchAt.filter { live.contains($0.key) }
        lastSuccessAt = lastSuccessAt.filter { live.contains($0.key) }
        lastError = lastError.filter { live.contains($0.key) }
        lastNotice = lastNotice.filter { live.contains($0.key) }
        cooldownUntil = cooldownUntil.filter { live.contains($0.key) }
    }

    private func pollDueAccounts(mode: PollMode = .background, forceActive: Bool = false) async {
        // Coalesce overlapping ticks (timer may fire while a slow adapter runs).
        guard !polling else { return }
        // While asleep, never hit vendor APIs (wake handler resumes).
        if systemAsleep, !forceActive { return }

        polling = true
        loading = true
        defer {
            polling = false
            loading = false
        }

        let accounts = accountStore.accounts
        guard !accounts.isEmpty else {
            widgets = []
            budgetCaption = ""
            return
        }

        let now = Date()
        let inactive = screenLocked && !forceActive && mode == .background
        var due: [Account] = []
        for account in accounts {
            if let until = cooldownUntil[account.id], now < until {
                continue
            }
            let minPoll = TimeInterval(
                VendorRegistry.adapter(for: account.vendorID)?.minPollSeconds ?? 300
            )
            let interval: TimeInterval
            switch mode {
            case .background:
                interval = inactive
                    ? max(Self.backgroundPollSeconds, Self.inactivePollFloor)
                    : Self.backgroundPollSeconds
            case .expand:
                interval = Self.expandInterval(minPoll: minPoll)
            case .force:
                // Manual refresh already cleared lastFetch; still floor minPoll
                // if we didn't clear (shouldn't happen).
                interval = minPoll
            }
            if Self.isDue(
                lastFetch: lastFetchAt[account.id],
                now: now,
                userInterval: interval,
                minPoll: minPoll
            ) {
                due.append(account)
            }
        }

        guard !due.isEmpty else {
            rebuildWidgets()
            return
        }

        let results = await fetchAccounts(due)

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

    /// Parallel fetch with concurrency cap (default 2).
    private func fetchAccounts(_ accounts: [Account]) async -> [(AccountID, UsageSnapshot)] {
        var collected: [(AccountID, UsageSnapshot)] = []
        collected.reserveCapacity(accounts.count)
        var index = 0
        while index < accounts.count {
            let end = min(index + Self.maxFetchConcurrency, accounts.count)
            let batch = Array(accounts[index..<end])
            index = end
            await withTaskGroup(of: (AccountID, UsageSnapshot).self) { group in
                for account in batch {
                    let ref = account.credentialRef
                    let vendorID = account.vendorID
                    let id = account.id
                    group.addTask {
                        if let adapter = VendorRegistry.adapter(for: vendorID) {
                            return (id, await adapter.fetchUsage(ref))
                        }
                        return (
                            id,
                            UsageSnapshot(
                                primary: WindowUsage(usedFraction: 0, kind: .unknown),
                                secondary: nil,
                                plan: nil,
                                fetchedAt: Date(),
                                error: .unavailable("unknown vendor")
                            )
                        )
                    }
                }
                for await item in group {
                    collected.append(item)
                }
            }
        }
        return collected
    }

    private func apply(accountID: AccountID, snapshot: UsageSnapshot, now: Date) {
        lastFetchAt[accountID] = now

        if let error = snapshot.error {
            lastError[accountID] = error
            lastNotice[accountID] = nil

            switch error {
            case .rateLimited(let retryAfter):
                cooldownUntil[accountID] = retryAfter
                    ?? now.addingTimeInterval(Self.rateLimitCooldown)
            case .authRequired:
                // Stop overnight 401 loops; user reauth / manual refresh clears this.
                cooldownUntil[accountID] = now.addingTimeInterval(Self.authFailureCooldown)
            default:
                break
            }

            // Soft retention: keep last good rings when we already have them.
            // Auth terminal also keeps rings if present but always surfaces caption.
            if lastGood[accountID] == nil {
                // Cold start with only an error — still store so hover/caption work.
                lastGood[accountID] = snapshot
            }
            return
        }

        // Success: clear error + cooldown, push burn smoother.
        lastError[accountID] = nil
        cooldownUntil[accountID] = nil
        lastSuccessAt[accountID] = now
        lastNotice[accountID] = snapshot.notice
        lastGood[accountID] = snapshot
        pushBurn(accountID: accountID, snapshot: snapshot)
    }

    // MARK: - View models

    private func rebuildWidgets() {
        let mode = preferences.displayMode
        widgets = accountStore.accounts.map { account in
            makeViewModel(account: account, mode: mode)
        }
        rebuildFetchStatuses()
    }

    private func rebuildFetchStatuses() {
        let now = Date()
        let bg = Self.backgroundPollSeconds
        fetchStatuses = accountStore.accounts.map { account in
            let attempt = lastFetchAt[account.id]
            let success = lastSuccessAt[account.id]
            let err = lastError[account.id]
            let cool = cooldownUntil[account.id]
            let outcome: AccountFetchStatus.Outcome
            if let cool, cool > now {
                if case .authRequired = err {
                    outcome = .failure(Self.caption(for: err, vendorID: account.vendorID) ?? "auth")
                } else if case .rateLimited = err {
                    outcome = .failure("cooling down")
                } else if let err {
                    outcome = .failure(Self.caption(for: err, vendorID: account.vendorID) ?? "failed")
                } else {
                    outcome = .failure("cooling down")
                }
            } else if attempt == nil {
                outcome = .never
            } else if let err {
                outcome = .failure(Self.caption(for: err, vendorID: account.vendorID) ?? "failed")
            } else {
                outcome = .success
            }

            let minPoll = TimeInterval(
                VendorRegistry.adapter(for: account.vendorID)?.minPollSeconds ?? 300
            )
            let interval = max(bg, minPoll)
            let nextDue: Date?
            if let cool, cool > now {
                nextDue = cool
            } else if let attempt {
                nextDue = attempt.addingTimeInterval(interval)
            } else {
                nextDue = now
            }

            return AccountFetchStatus(
                id: account.id,
                label: account.label,
                vendorID: account.vendorID,
                lastAttemptAt: attempt,
                lastSuccessAt: success,
                cooldownUntil: cool.flatMap { $0 > now ? $0 : nil },
                nextDueAt: nextDue,
                outcome: outcome
            )
        }
        budgetCaption = Self.estimateBudgetCaption(accounts: accountStore.accounts)
    }

    /// Rough upper bound for **background** traffic only (expand is extra, on demand).
    nonisolated static func estimateBudgetCaption(accounts: [Account]) -> String {
        guard !accounts.isEmpty else { return "" }
        var perHour = 0.0
        let bg = backgroundPollSeconds
        for account in accounts {
            let minPoll = Double(VendorRegistry.adapter(for: account.vendorID)?.minPollSeconds ?? 300)
            let interval = max(bg, minPoll)
            let weight = account.vendorID == "grok" ? 1.15 : 1.0
            perHour += weight * (3600.0 / interval)
        }
        let n = Int(perHour.rounded(.up))
        return "~\(n) API calls/h bg · 15m · expand refreshes stale · \(accounts.count) acct"
    }

    private func makeViewModel(
        account: Account,
        mode: PreferencesStore.DisplayMode
    ) -> WidgetViewModel {
        let snap = lastGood[account.id]
        let usedPrimary = snap?.primary.usedFraction ?? 0
        let usedSecondary = snap?.secondary?.usedFraction

        let primaryFraction = Self.displayFraction(used: usedPrimary, mode: mode)
        let secondaryFraction = usedSecondary.map {
            Self.displayFraction(used: $0, mode: mode)
        }

        let burn = burnByAccount[account.id]?.current
            ?? BurnRate(ratio: 0, sampleCount: 0)
        let err = lastError[account.id] ?? snap?.error
        let awaiting = snap == nil && err == nil
        let notice = lastNotice[account.id] ?? snap?.notice
        let burnSource = burnSourceByAccount[account.id] ?? .none

        return WidgetViewModel(
            id: account.id,
            title: account.label,
            vendorID: account.vendorID,
            tint: Self.tint(for: account.vendorID),
            primaryFraction: awaiting ? 0 : primaryFraction,
            secondaryFraction: awaiting ? nil : secondaryFraction,
            usedPrimaryFraction: usedPrimary,
            centerPercent: awaiting ? 0 : Int((primaryFraction * 100).rounded()),
            burnRatio: awaiting ? 0 : burn.ratio,
            burnSource: awaiting ? .none : burnSource,
            hoverWindows: awaiting
                ? [HoverWindowLine(label: "…", usage: "waiting for first poll", resetAt: nil)]
                : Self.hoverWindows(snapshot: snap, mode: mode),
            errorCaption: Self.caption(for: err, vendorID: account.vendorID),
            noticeCaption: awaiting ? nil : notice,
            isAwaitingFirstSample: awaiting
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

    nonisolated static func caption(for error: UsageError?, vendorID: VendorID = "") -> String? {
        guard let error else { return nil }
        switch error {
        case .authRequired:
            switch vendorID {
            case "claude": return "reauth: claude auth login"
            case "codex": return "reauth: codex login"
            case "grok": return "reauth: grok login --oauth"
            default: return "reauth required"
            }
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

    /// Hover rows: primary + secondary rings, then scoped extras (Fable, …).
    nonisolated static func hoverWindows(
        snapshot: UsageSnapshot?,
        mode: PreferencesStore.DisplayMode
    ) -> [HoverWindowLine] {
        guard let snapshot else { return [] }
        var lines: [HoverWindowLine] = []
        lines.append(windowLine(window: snapshot.primary, mode: mode))
        if let secondary = snapshot.secondary {
            lines.append(windowLine(window: secondary, mode: mode))
        }
        for extra in snapshot.extras {
            lines.append(windowLine(window: extra, mode: mode))
        }
        return lines
    }

    nonisolated private static func windowLine(
        window: WindowUsage,
        mode: PreferencesStore.DisplayMode
    ) -> HoverWindowLine {
        let label = window.displayLabel
        let usage: String
        if let used = window.usedTokens, let limit = window.limitTokens, limit > 0 {
            usage = "\(formatTokens(used)) / \(formatTokens(limit))"
        } else {
            let fraction = displayFraction(used: window.usedFraction, mode: mode)
            let pct = Int((fraction * 100).rounded())
            usage = "\(pct)%"
        }
        return HoverWindowLine(label: label, usage: usage, resetAt: window.resetAt)
    }

    /// Compact remaining time until reset: `1d 5h`, `5h 12m`, `42m`, `<1m`.
    nonisolated static func formatResetRemaining(
        until resetAt: Date,
        now: Date = Date()
    ) -> String? {
        let seconds = resetAt.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let mins = (total % 3_600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
        if mins > 0 { return "\(mins)m" }
        return "<1m"
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
