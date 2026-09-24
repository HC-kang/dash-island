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
/// - Sleep: no network; wake: one poll after a 60s grace; lock: floor 30m;
///   launch: one seed poll.
@MainActor
final class UsageOrchestrator: ObservableObject {
    static let shared = UsageOrchestrator(
        accountStore: .shared,
        preferences: .shared
    )

    /// Background cadence for an account that is **not** burning. A quiet account's
    /// percentage does not move, so asking more often buys nothing and only spends
    /// request budget we want available for the accounts that are moving.
    nonisolated static let backgroundPollSeconds: TimeInterval = 15 * 60
    /// Background cadence for an account with captured activity since its last
    /// sample, or one that just jumped. Five-hour utilization can climb tens of
    /// percent in minutes, so a flat 15m is useless exactly when it matters.
    /// The vendor's own `minPollSeconds` is still the hard floor.
    nonisolated static let activePollSeconds: TimeInterval = 60
    /// Primary-window movement that counts as "this account is burning" even when
    /// no telemetry reached the collector (web use, or a process that predates it).
    nonisolated static let activeDeltaThreshold = 0.01
    /// Poll again soon after a window rolls over, so a full ring does not sit at
    /// 100% for a whole idle interval after it has actually reset.
    nonisolated static let postResetGrace: TimeInterval = 120
    /// Scheduler tick. Deliberately shorter than the shortest poll interval —
    /// `isDue` enforces the real per-account spacing. A tick equal to the interval
    /// aliased to ~2×: `lastFetchAt` was stamped *after* the HTTP round trip, so the
    /// next tick was always a few hundred ms early and skipped the account. Now the
    /// stamp is the fetch start and `isDue` allows `dueTolerance` of slack.
    nonisolated static let schedulerTickSeconds: TimeInterval = 20
    /// Expand/lazy floor — never more often than this even if minPoll is lower.
    nonisolated static let expandDebounceFloor: TimeInterval = 120
    /// Max concurrent vendor HTTP fetches (multi-account spike control).
    nonisolated static let maxFetchConcurrency = 2
    /// First local quiet window after a 429 when the vendor omits Retry-After.
    /// Was 2h, which turned a single usage 429 into a 2h blackout and forced the
    /// whole product to poll slowly. The streak below is the multiplicative half
    /// of the backoff; a success clears it (`apply`), which is the additive half.
    nonisolated static let rateLimitCooldown: TimeInterval = 15 * 60
    /// Cap for *local* streak backoff (15m/30m/1h/2h/4h). Retry-After may exceed it.
    nonisolated static let rateLimitCooldownMax: TimeInterval = 6 * 60 * 60
    /// After auth failure, back off so we do not 401-spam overnight.
    nonisolated static let authFailureCooldown: TimeInterval = 30 * 60
    /// While the Mac is asleep / screen locked, floor poll spacing.
    nonisolated static let inactivePollFloor: TimeInterval = 30 * 60
    /// First retry after a network error, then doubling. Without it an idle
    /// account waited the full 15m after one DNS blip or a wake before Wi-Fi.
    nonisolated static let transientRetryBase: TimeInterval = 60
    /// Backoff cap; stays below `backgroundPollSeconds` so a failure never
    /// makes an account slower than idle.
    nonisolated static let transientRetryMax: TimeInterval = 8 * 60

    enum PollMode: Equatable, Sendable {
        /// Timer / wake: `backgroundPollSeconds` × minPoll.
        case background
        /// Island expanded (after dwell): fresher, but still minPoll-floor.
        case expand
        /// Manual refresh — still respects minPoll unless cooldowns cleared by `refresh()`.
        case force

        fileprivate var rank: Int {
            switch self {
            case .background: return 0
            case .expand: return 1
            case .force: return 2
            }
        }
    }

    /// What to run after the poll in flight. Event polls (`forceActive`:
    /// launch, wake, account change, expand, refresh) are queued, the strongest
    /// wins; plain timer ticks just wait for the next tick.
    nonisolated static func queuedPoll(
        pending: PollMode?,
        incoming: PollMode,
        forceActive: Bool
    ) -> PollMode? {
        guard forceActive else { return pending }
        guard let pending else { return incoming }
        return incoming.rank > pending.rank ? incoming : pending
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
    /// Retry time a soft failure named (`UsageSnapshot.retryAt`). The account
    /// is due then, not one idle interval later (`isDue`).
    private var retryDueAt: [AccountID: Date] = [:]
    /// Consecutive rate-limit hits → longer quiet windows (1×, 2×, 3× base… capped).
    private var rateLimitStreak: [AccountID: Int] = [:]
    /// Consecutive network errors → short retry backoff (`transientRetryWait`).
    private var networkFailureStreak: [AccountID: Int] = [:]
    /// Soft notices (token expiring soon).
    private var lastNotice: [AccountID: String] = [:]
    /// Between-poll ring extension learned from captured local spend.
    private var projectionByAccount: [AccountID: UsageProjection] = [:]
    /// Cached collector identity per account (file read, not per tick).
    private var projectionIdentity: [AccountID: String] = [:]
    /// Primary-window movement between the last two API samples. Keeps a burning
    /// account fast even when the collector never saw its calls.
    private var lastPrimaryDelta: [AccountID: Double] = [:]

    private var timer: Timer?
    /// Local-only Claude needle tick (no network).
    private var burnTimer: Timer?
    /// Read positions for local Claude logs; lives as long as the orchestrator.
    private let claudeLogCache = ClaudeActivity.LogCache()
    /// One local log scan at a time (it runs off the main actor).
    private var burnScanInFlight = false
    private var cancellables = Set<AnyCancellable>()
    private var powerObservers: [NSObjectProtocol] = []
    private var started = false
    private var polling = false
    /// Event poll that arrived while `polling`; runs right after (`queuedPoll`).
    private var pendingPoll: PollMode?
    /// Guards against applying a result fetched with replaced credentials.
    private var generations = PollGenerations()
    /// Accounts with a fetch running right now (`beginReauth` waits for them).
    private var fetchingNow: Set<AccountID> = []
    /// True between willSleep and didWake — skip network polls.
    private var systemAsleep = false
    /// Screen locked (optional extra inactive floor when awake).
    private var screenLocked = false
    /// Network polls wait until this instant after a wake (`WakeScheduling`).
    private var wakeGraceUntil: Date?
    /// The one poll scheduled for the end of the wake grace.
    private var wakePollTask: Task<Void, Never>?
    /// When the repeating scheduler timer should fire next; a much later fire
    /// is the catch-up fire of a sleep.
    private var nextExpectedTick: Date?

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

        NotificationCenter.default.addObserver(
            forName: .dashIslandVendorStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildWidgets() }
        }

        installPowerObservers()
        rescheduleTimer()
        rescheduleBurnTimer()
        VendorStatusStore.shared.start()
        rebuildWidgets()
        // Launch seed — one background pass so rings aren't empty.
        Task { await pollDueAccounts(mode: .background, forceActive: true) }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        burnTimer?.invalidate()
        burnTimer = nil
        VendorStatusStore.shared.stop()
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
        pendingPoll = nil
        wakePollTask?.cancel()
        wakePollTask = nil
        wakeGraceUntil = nil
    }

    /// Force a poll. Optionally mark one account immediately due (e.g. after reauth).
    /// Clears cooldown for the target account (or all when nil).
    func refresh(accountID: AccountID? = nil) {
        if let accountID {
            lastFetchAt[accountID] = nil
            cooldownUntil[accountID] = nil
            retryDueAt[accountID] = nil
            // Reauth: a fetch still running used the old credentials; drop its result.
            generations.bump(accountID)
            resetIdentityState(accountID)
        } else {
            for id in accountStore.accounts.map(\.id) {
                lastFetchAt[id] = nil
                cooldownUntil[id] = nil
                retryDueAt[id] = nil
            }
        }
        rebuildWidgets()
        Task { await pollDueAccounts(mode: .force, forceActive: true) }
    }

    /// After a reauth the slot may hold a different login. Never carry signals
    /// from the old identity over: the cached collector identity, the projection
    /// and its activity delta, and the burn history go. Last-good rings go only
    /// when both identities are known and differ; otherwise the forced poll
    /// replaces them.
    private func resetIdentityState(_ id: AccountID) {
        let old = projectionIdentity[id]
        projectionIdentity[id] = nil
        projectionByAccount[id] = nil
        lastPrimaryDelta[id] = nil
        burnByAccount[id] = nil
        burnSourceByAccount[id] = nil
        guard let account = accountStore.accounts.first(where: { $0.id == id }),
              Self.projectableVendors.contains(account.vendorID)
        else { return }
        let home = CredentialStore.directoryURL(for: account.credentialRef)
        let new = AccountUsageReader.identity(provider: account.vendorID, home: home)
        if Self.reauthDropsLastGood(oldIdentity: old, newIdentity: new) {
            lastGood[id] = nil
            lastSuccessAt[id] = nil
            lastNotice[id] = nil
            // Or `restoreLastGoodSnapshots` would reload the old login's rings.
            CredentialStore.removeLastGoodUsage(inDirectory: home)
            Log.accounts.info("reauth account=\(id.short) identity=changed lastGood=dropped")
        }
    }

    nonisolated static func reauthDropsLastGood(oldIdentity: String?, newIdentity: String?) -> Bool {
        guard let oldIdentity, let newIdentity else { return false }
        return oldIdentity != newIdentity
    }

    /// Longest wait for a fetch that was already running when reauth started.
    nonisolated static let reauthFetchWait: TimeInterval = 30

    /// Reauthenticate is about to start. The adapter moves the session files
    /// aside while the sign-in runs; a poll then read "no credentials" and left
    /// a false red reauth with a 30m cooldown after Cancel. Hold this account
    /// until `endReauth`, and let a fetch already running finish first: its
    /// token refresh could write a file the login wait takes for the new sign-in.
    func beginReauth(accountID: AccountID) async {
        generations.hold(accountID)
        Log.poll.info("hold account=\(accountID.short) reason=reauth")
        let deadline = Date().addingTimeInterval(Self.reauthFetchWait)
        while fetchingNow.contains(accountID), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Reauth ended, with any outcome. After a success the files hold a new
    /// session: poll it now. After Cancel or a failure the old files are back
    /// and no poll ran on the gap, so the normal schedule goes on.
    func endReauth(accountID: AccountID, succeeded: Bool) {
        generations.release(accountID)
        Log.poll.info("release account=\(accountID.short) reason=reauth succeeded=\(succeeded)")
        if succeeded {
            refresh(accountID: accountID)
        } else {
            rebuildWidgets()
        }
    }

    /// Island became expanded (caller should dwell ~400ms first). Lazy refresh
    /// stale accounts without clearing 429/auth cooldowns.
    func onIslandExpanded() {
        Task { await pollDueAccounts(mode: .expand, forceActive: true) }
    }

    /// Hold network polls for `WakeScheduling.graceDelay`, then poll once.
    /// Called by the wake notification and by an overdue scheduler tick;
    /// whichever comes second restarts the same grace.
    private func beginWakeGrace(now: Date) {
        wakeGraceUntil = now.addingTimeInterval(WakeScheduling.graceDelay)
        wakePollTask?.cancel()
        wakePollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WakeScheduling.graceDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.systemAsleep else { return }
            self.wakePollTask = nil
            // The sleep clock and the wall clock can disagree by a hair.
            self.wakeGraceUntil = nil
            await self.pollDueAccounts(mode: .background, forceActive: true)
        }
    }

    private func schedulerTick() async {
        let now = Date()
        let expected = nextExpectedTick
        nextExpectedTick = now.addingTimeInterval(Self.schedulerTickSeconds)
        // The run loop delivers one catch-up fire right at wake, sometimes before
        // (or without) the wake notification. A timer that fired at all means
        // the Mac is awake.
        if WakeScheduling.isOverdueFire(now: now, expected: expected) {
            Log.poll.info("power event=wake source=overdueTick late=\(Int(now.timeIntervalSince(expected ?? now)))s")
            systemAsleep = false
            beginWakeGrace(now: now)
            return
        }
        await pollDueAccounts(mode: .background)
    }

    private func installPowerObservers() {
        let wsnc = NSWorkspace.shared.notificationCenter
        powerObservers.append(
            wsnc.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    Log.poll.info("power event=sleep")
                    self?.systemAsleep = true
                    self?.wakePollTask?.cancel()
                    self?.wakePollTask = nil
                }
            }
        )
        powerObservers.append(
            wsnc.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    Log.poll.info("power event=wake")
                    self?.systemAsleep = false
                    self?.beginWakeGrace(now: Date())
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
                Task { @MainActor in
                    Log.poll.info("power event=lock")
                    self?.screenLocked = true
                }
            }
        )
        powerObservers.append(
            dnc.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    Log.poll.info("power event=unlock")
                    self?.screenLocked = false
                }
            }
        )
    }

    // MARK: - Due helper (pure, testable)

    /// Whether an account should be fetched at `now`.
    ///
    /// Due if never fetched, or `now - lastFetch >= max(userInterval, minPoll) - tolerance`.
    /// `retryAt` is the retry time a soft failure named (token gate, CLI ping).
    /// It is due then, even when the idle interval is longer; `minPoll` stays
    /// the floor.
    nonisolated static func isDue(
        lastFetch: Date?,
        now: Date,
        userInterval: TimeInterval,
        minPoll: TimeInterval,
        tolerance: TimeInterval = 0,
        retryAt: Date? = nil
    ) -> Bool {
        guard let lastFetch else { return true }
        if let retryAt, now >= retryAt,
           now.timeIntervalSince(lastFetch) >= minPoll - tolerance
        {
            return true
        }
        let interval = max(userInterval, minPoll)
        guard interval > 0 else { return true }
        return now.timeIntervalSince(lastFetch) >= interval - tolerance
    }

    /// Slack for `isDue`. Ticks land on a fixed grid with run-loop jitter, and a
    /// fetch may start a few seconds after its tick; an exact comparison missed
    /// the 60s slot by milliseconds and polled at 80s. Half a tick can never
    /// pull a poll a whole tick early.
    nonisolated static let dueTolerance: TimeInterval = schedulerTickSeconds / 2

    /// Interval used for expand lazy-refresh: never below `expandDebounceFloor`
    /// or the vendor's `minPollSeconds`.
    nonisolated static func expandInterval(minPoll: TimeInterval) -> TimeInterval {
        max(expandDebounceFloor, minPoll)
    }

    /// Cooldown seconds after a rate limit. Local 2h/4h/6h backoff is capped;
    /// an explicit vendor `Retry-After` is authoritative even when longer.
    nonisolated static func rateLimitWait(
        streak: Int,
        retryAfter: Date?,
        now: Date
    ) -> TimeInterval {
        let vendor = retryAfter.map { $0.timeIntervalSince(now) } ?? 0
        // First 429 with an explicit Retry-After: the vendor knows its own window.
        if streak <= 1, vendor > 0 { return max(60, vendor) }
        // Repeats double: 15m, 30m, 1h, 2h, 4h — capped locally, never below the
        // vendor's own ask.
        let steps = max(0, min(streak, 5) - 1)
        let local = min(rateLimitCooldownMax, rateLimitCooldown * pow(2, Double(steps)))
        return max(60, max(local, vendor))
    }

    /// Spacing after `streak` network errors in a row: 1m, 2m, 4m, then 8m.
    nonisolated static func transientRetryWait(streak: Int) -> TimeInterval {
        let steps = max(0, min(streak, 4) - 1)
        return min(transientRetryMax, transientRetryBase * pow(2, Double(steps)))
    }

    // MARK: - Polling

    private func rescheduleTimer() {
        timer?.invalidate()
        let seconds = Self.schedulerTickSeconds
        let t = Timer(timeInterval: max(1, seconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.schedulerTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        nextExpectedTick = Date().addingTimeInterval(max(1, seconds))
    }

    private func rescheduleBurnTimer() {
        burnTimer?.invalidate()
        let t = Timer(timeInterval: Self.localBurnSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.sampleLocalBurnActivity()
                await self?.refreshProjections()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        burnTimer = t
    }

    private func onAccountsChanged() {
        pruneState()
        restoreLastGoodSnapshots()
        rebuildWidgets()
        Task { await pollDueAccounts(mode: .background, forceActive: true) }
    }

    /// **No network.** Refresh Claude needles from local session logs only.
    /// Prefers managed `CLAUDE_CONFIG_DIR` project trees per account; host-wide fallback.
    /// The scan reads and parses files, so it runs off the main actor; only the
    /// ratios come back here. It no longer skips while a poll is in flight: both
    /// timers fire on the same second, so that guard dropped most samples of a
    /// busy account.
    private func sampleLocalBurnActivity() async {
        guard !burnScanInFlight, !systemAsleep else { return }
        let targets = accountStore.accounts
            .filter { $0.vendorID == "claude" }
            .map { (id: $0.id, dir: CredentialStore.directoryURL(for: $0.credentialRef)) }
        guard !targets.isEmpty else { return }
        burnScanInFlight = true
        defer { burnScanInFlight = false }

        let now = Date()
        let cache = claudeLogCache
        let ratios = await Task.detached(priority: .utility) { () -> [(id: AccountID, ratio: Double)] in
            let out = targets.map {
                (id: $0.id, ratio: ClaudeActivity.liveBurnRatio(now: now, configDir: $0.dir, cache: cache))
            }
            cache.evict(unseenSince: now.addingTimeInterval(-3600))
            return out
        }.value

        let live = Set(accountStore.accounts.map(\.id))
        var changed = false
        for (id, ratio) in ratios where ratio > 0 && live.contains(id) {
            var smoother = burnByAccount[id] ?? BurnSmoother()
            let before = smoother.current.ratio
            _ = smoother.noteLiveActivity(ratio: ratio, at: now)
            burnByAccount[id] = smoother
            mergeBurnSource(accountID: id, local: true)
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
        Log.burn.debug(
            "sample account=\(accountID.short) kind=\(burnWin.kind.rawValue) u=\(String(format: "%.4f", burnWin.usedFraction)) abs=\(burnWin.hasAbsoluteCounters ? "y" : "n") ratio=\(String(format: "%.3f", result.ratio)) samples=\(result.sampleCount)"
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
        retryDueAt = retryDueAt.filter { live.contains($0.key) }
        rateLimitStreak = rateLimitStreak.filter { live.contains($0.key) }
        networkFailureStreak = networkFailureStreak.filter { live.contains($0.key) }
        projectionByAccount = projectionByAccount.filter { live.contains($0.key) }
        projectionIdentity = projectionIdentity.filter { live.contains($0.key) }
        lastPrimaryDelta = lastPrimaryDelta.filter { live.contains($0.key) }
        generations.prune(live: live)
    }

    /// Reload error-free rings from disk so restart + soft quiet keeps gauges.
    private func restoreLastGoodSnapshots() {
        var restored = 0
        for account in accountStore.accounts where lastGood[account.id] == nil {
            let url = CredentialStore.lastGoodUsageURL(for: account.credentialRef)
            guard let snapshot = Self.loadLastGood(from: url) else { continue }
            lastGood[account.id] = snapshot
            lastSuccessAt[account.id] = snapshot.fetchedAt
            lastNotice[account.id] = String(localized: "saved last-good · checking live usage")
            lastUpdated = max(lastUpdated ?? .distantPast, snapshot.fetchedAt)
            restored += 1
        }
        if restored > 0 { Log.accounts.info("lastGood restore count=\(restored)") }
    }

    private func persistLastGood(accountID: AccountID, snapshot: UsageSnapshot) {
        guard let account = accountStore.accounts.first(where: { $0.id == accountID }) else { return }
        if !Self.saveLastGood(
            snapshot,
            to: CredentialStore.lastGoodUsageURL(for: account.credentialRef)
        ) {
            Log.accounts.warn("lastGood persist failed account=\(accountID.short)")
        }
    }

    nonisolated static func encodeLastGood(_ snapshot: UsageSnapshot) -> Data? {
        guard snapshot.error == nil, snapshot.primary.isReported else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(snapshot)
    }

    nonisolated static func decodeLastGood(_ data: Data) -> UsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let snapshot = try? decoder.decode(UsageSnapshot.self, from: data),
              snapshot.error == nil
        else { return nil }
        return snapshot
    }

    @discardableResult
    nonisolated static func saveLastGood(_ snapshot: UsageSnapshot, to url: URL) -> Bool {
        guard let data = encodeLastGood(snapshot) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    nonisolated static func loadLastGood(from url: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeLastGood(data)
    }

    private func pollDueAccounts(mode: PollMode = .background, forceActive: Bool = false) async {
        // Coalesce overlapping ticks (timer may fire while a slow adapter runs).
        // A user or event request is queued and runs right after, never dropped.
        guard !polling else {
            let queued = Self.queuedPoll(pending: pendingPoll, incoming: mode, forceActive: forceActive)
            if queued != pendingPoll {
                pendingPoll = queued
                Log.poll.debug("tick queue reason=inflight mode=\(mode)")
            } else {
                Log.poll.debug("tick skip reason=inflight mode=\(mode)")
            }
            return
        }
        // While asleep, never hit vendor APIs (wake handler resumes).
        if systemAsleep, !forceActive {
            Log.poll.debug("tick skip reason=asleep mode=\(mode)")
            return
        }
        // Just woke: the wake poll at the end of the grace covers everyone.
        if WakeScheduling.holdsPoll(now: Date(), graceUntil: wakeGraceUntil, manual: mode == .force) {
            Log.poll.debug("tick skip reason=wakeGrace mode=\(mode)")
            return
        }

        polling = true
        defer { polling = false }
        await runPoll(mode: mode, forceActive: forceActive)
        while let next = pendingPoll {
            pendingPoll = nil
            if WakeScheduling.holdsPoll(now: Date(), graceUntil: wakeGraceUntil, manual: next == .force) {
                continue
            }
            await runPoll(mode: next, forceActive: true)
        }
    }

    private func runPoll(mode: PollMode, forceActive: Bool) async {
        let accounts = accountStore.accounts
        guard !accounts.isEmpty else {
            if !widgets.isEmpty { widgets = [] }
            if !budgetCaption.isEmpty { budgetCaption = "" }
            return
        }

        let now = Date()
        // Free expired cooldown slots only — keep lastError until a *success*
        // so we do not look healthy, re-hit the vendor, and paint red again.
        expireCooldowns(now: now)

        let inactive = screenLocked && !forceActive && mode == .background
        var due: [Account] = []
        for account in accounts {
            if generations.isHeld(account.id) {
                Log.poll.debug("skip account=\(account.id.short) reason=reauth")
                continue
            }
            if let until = cooldownUntil[account.id], now < until {
                // 20h-stale last-good + 4h 429 lock looked dead. Expand/force
                // retry when the last *success* is older than 2h.
                let lastOK = lastSuccessAt[account.id]
                let veryStale = lastOK.map { now.timeIntervalSince($0) >= 2 * 3600 } ?? true
                if !(mode == .expand && veryStale) {
                    Log.poll.debug("skip account=\(account.id.short) reason=cooldown in=\(Int(until.timeIntervalSince(now)))s")
                    continue
                }
            }
            let minPoll = TimeInterval(
                VendorRegistry.adapter(for: account.vendorID)?.minPollSeconds ?? 300
            )
            let interval: TimeInterval
            switch mode {
            case .background:
                interval = backgroundInterval(for: account, now: now, screenLocked: inactive)
            case .expand:
                // Expand is lazy refresh — still respect rate-limit quiet windows
                // (do not let hover thrash OAuth token endpoints).
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
                minPoll: minPoll,
                tolerance: Self.dueTolerance,
                retryAt: retryDueAt[account.id]
            ) {
                due.append(account)
            } else {
                Log.poll.debug("skip account=\(account.id.short) reason=interval every=\(Int(interval))s")
            }
        }

        guard !due.isEmpty else {
            rebuildWidgets()
            return
        }

        // Only a poll that goes to the network shows the spinner.
        loading = true
        defer { loading = false }
        Log.poll.info("tick mode=\(mode) due=\(due.count)/\(accounts.count) locked=\(inactive)")
        await fetchAccounts(due)
    }

    /// At most `maxFetchConcurrency` requests in flight. A slot frees as soon as
    /// its account answers, and each result is applied on arrival, so one slow
    /// vendor holds one slot instead of the whole batch.
    private func fetchAccounts(_ accounts: [Account]) async {
        await Self.forEachBounded(
            accounts,
            limit: Self.maxFetchConcurrency,
            start: { queued -> FetchJob? in
                // Read the account again: it may have been removed or reauthed
                // (new credentialRef) while it waited for a slot.
                guard let account = self.accountStore.accounts.first(where: { $0.id == queued.id }),
                      !self.generations.isHeld(account.id)
                else {
                    return nil
                }
                self.fetchingNow.insert(account.id)
                return FetchJob(account: account, startedAt: Date(), generation: self.generations.current(account.id))
            },
            work: { job in await Self.fetchOne(job.account) },
            finish: { job, snapshot in
                let id = job.account.id
                self.fetchingNow.remove(id)
                let live = Set(self.accountStore.accounts.map(\.id))
                guard self.generations.accepts(id, generation: job.generation, live: live) else {
                    Log.poll.info("discard account=\(id.short) reason=stale")
                    return
                }
                let applyAt = Date()
                self.apply(accountID: id, snapshot: snapshot, startedAt: job.startedAt, now: applyAt)
                if snapshot.error == nil || self.lastUpdated == nil {
                    self.lastUpdated = applyAt
                }
                self.rebuildWidgets()
            }
        )
    }

    private struct FetchJob: Sendable {
        let account: Account
        /// Spacing is measured start to start. Stamping after the round trip
        /// made every interval one fetch longer than asked.
        let startedAt: Date
        /// `PollGenerations.current` when the fetch started.
        let generation: Int
    }

    nonisolated private static func fetchOne(_ account: Account) async -> UsageSnapshot {
        let started = Date()
        let snapshot: UsageSnapshot
        if let adapter = VendorRegistry.adapter(for: account.vendorID) {
            snapshot = await adapter.fetchUsage(account.credentialRef)
        } else {
            snapshot = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0, kind: .unknown),
                secondary: nil,
                plan: nil,
                fetchedAt: Date(),
                error: .unavailable("unknown vendor")
            )
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let line = "usage vendor=\(account.vendorID) account=\(account.id.short) ms=\(ms)"
        let outcome: String
        switch snapshot.error {
        case nil: outcome = "ok"
        case .rateLimited?: outcome = "rateLimited"
        case .authRequired?: outcome = "authRequired"
        case .network?: outcome = "network"
        case .parse?: outcome = "parse"
        case .unavailable?: outcome = "unavailable"
        }
        if let error = snapshot.error {
            // The one failure line per fetch (adapters no longer log their own).
            // Error payloads are app-built strings, never response bodies.
            Log.fetch.warn("\(line) outcome=\(outcome) error=\(String(describing: error))")
        } else {
            Log.fetch.info("\(line) outcome=\(outcome)")
        }
        return snapshot
    }

    /// Run `work` for each item with at most `limit` jobs in flight. `start`
    /// runs on the caller's actor right before an item starts (nil skips it);
    /// `finish` runs there as soon as that job's result lands.
    static func forEachBounded<Item, Job: Sendable, Result: Sendable>(
        _ items: [Item],
        limit: Int,
        isolation: isolated (any Actor)? = #isolation,
        start: (Item) -> Job?,
        work: @escaping @Sendable (Job) async -> Result,
        finish: (Job, Result) -> Void
    ) async {
        var waiting = items[...]
        await withTaskGroup(of: (Job, Result).self) { group in
            var running = 0
            while true {
                while running < max(1, limit), let item = waiting.popFirst() {
                    guard let job = start(item) else { continue }
                    group.addTask { (job, await work(job)) }
                    running += 1
                }
                guard let (job, result) = await group.next() else { break }
                running -= 1
                finish(job, result)
            }
        }
    }

    private func apply(accountID: AccountID, snapshot: UsageSnapshot, startedAt: Date, now: Date) {
        lastFetchAt[accountID] = startedAt
        retryDueAt[accountID] = nil

        // Any answer from the vendor, good or bad, ends a network outage.
        if case .network = snapshot.error {
            let streak = (networkFailureStreak[accountID] ?? 0) + 1
            networkFailureStreak[accountID] = streak
            // isDue floors every interval at the vendor's minPoll, so log the wait that
            // actually applies (agy: 300 s), not the raw backoff step.
            let vendor = accountStore.accounts.first { $0.id == accountID }?.vendorID ?? ""
            let minPoll = TimeInterval(VendorRegistry.adapter(for: vendor)?.minPollSeconds ?? 300)
            let wait = max(Self.transientRetryWait(streak: streak), minPoll)
            Log.poll.info("retry account=\(accountID.short) kind=network streak=\(streak) in=\(Int(wait))s")
        } else {
            networkFailureStreak[accountID] = nil
        }

        if let error = snapshot.error {
            lastError[accountID] = error
            let kind = UsageSnapshotMerge.failureKind(error)

            switch error {
            case .rateLimited(let retryAfter):
                let streak = (rateLimitStreak[accountID] ?? 0) + 1
                rateLimitStreak[accountID] = streak
                let wait = Self.rateLimitWait(streak: streak, retryAfter: retryAfter, now: now)
                cooldownUntil[accountID] = now.addingTimeInterval(wait)
                Log.poll.info("cooldown account=\(accountID.short) kind=429 streak=\(streak) wait=\(Int(wait / 60))m")
            case .authRequired:
                // Stop overnight 401 loops; user reauth / manual refresh clears this.
                cooldownUntil[accountID] = now.addingTimeInterval(Self.authFailureCooldown)
                Log.poll.info("cooldown account=\(accountID.short) kind=auth wait=\(Int(Self.authFailureCooldown / 60))m")
            case .unavailable where kind == .soft:
                // Retry exactly when the token gate opens; otherwise short spacing
                // so we do not thrash oauth/token.
                // Log only when a cooldown is actually set, not when one already runs.
                if let retryAt = snapshot.retryAt {
                    cooldownUntil[accountID] = retryAt
                    retryDueAt[accountID] = retryAt
                    Log.poll.info("cooldown account=\(accountID.short) kind=soft wait=\(Int(retryAt.timeIntervalSince(now) / 60))m source=retryAt")
                } else if cooldownUntil[accountID] == nil {
                    cooldownUntil[accountID] = now.addingTimeInterval(30 * 60)
                    Log.poll.info("cooldown account=\(accountID.short) kind=soft wait=30m source=default")
                }
            default:
                break
            }

            // Never write an *error* snapshot into lastGood — that paints a fake 0%
            // ring ("token quiet" with empty gauge). Only error-free samples are last-good.
            if UsageSnapshotMerge.shouldRetainPreviousRings(previous: lastGood[accountID]) {
                if kind == .soft {
                    lastNotice[accountID] = UsageSnapshotMerge.softStaleNotice(for: error)
                } else {
                    lastNotice[accountID] = nil
                }
            } else {
                // No prior good sample: leave lastGood nil (skeleton), error caption only.
                lastNotice[accountID] = nil
            }
            return
        }

        // Success: clear error + cooldown + streak, push burn smoother.
        lastError[accountID] = nil
        cooldownUntil[accountID] = nil
        rateLimitStreak[accountID] = nil
        lastSuccessAt[accountID] = now
        lastNotice[accountID] = snapshot.notice
        // Placeholder sample (vendor reported no windows): never replace real rings,
        // never persist it, never push its fake 0% into the burn smoother.
        guard snapshot.primary.isReported else {
            if lastGood[accountID] == nil { lastGood[accountID] = snapshot }
            return
        }
        if let previous = lastGood[accountID],
           previous.primary.resetAt == snapshot.primary.resetAt
        {
            lastPrimaryDelta[accountID] = max(
                0,
                snapshot.primary.usedFraction - previous.primary.usedFraction
            )
        } else {
            lastPrimaryDelta[accountID] = 0
        }
        lastGood[accountID] = snapshot
        persistLastGood(accountID: accountID, snapshot: snapshot)
        QuotaHistoryStore.shared.record(accountID: accountID, snapshot: snapshot, at: now)
        pushBurn(accountID: accountID, snapshot: snapshot)
        anchorProjection(accountID: accountID, snapshot: snapshot, now: now)
    }

    /// Background spacing for one account: fast while it burns or just after its
    /// window rolls over, slow while it sits still.
    ///
    /// Two independent activity signals, because neither alone is complete —
    /// captured calls are accurate but blind to web use and to processes that
    /// predate telemetry, while the last API step is always available but one
    /// sample behind.
    nonisolated static func backgroundInterval(
        spentSinceAnchor: Double?,
        lastPrimaryDelta: Double?,
        windowResetAt: Date?,
        screenLocked: Bool,
        networkFailures: Int = 0,
        now: Date
    ) -> TimeInterval {
        // A failing network is its own schedule: sooner than idle, later than busy.
        if networkFailures > 0 { return transientRetryWait(streak: networkFailures) }
        if let windowResetAt, now >= windowResetAt,
           now.timeIntervalSince(windowResetAt) <= postResetGrace
        {
            return activePollSeconds
        }
        // A locked screen does not stop an agent from burning tokens, and this
        // user's longest runs happen while they are away from the Mac. The
        // inactive floor is for accounts that are genuinely doing nothing.
        if let spentSinceAnchor, spentSinceAnchor > 0 { return activePollSeconds }
        if let lastPrimaryDelta, lastPrimaryDelta >= activeDeltaThreshold { return activePollSeconds }
        return screenLocked
            ? max(backgroundPollSeconds, inactivePollFloor)
            : backgroundPollSeconds
    }

    private func backgroundInterval(for account: Account, now: Date, screenLocked: Bool = false) -> TimeInterval {
        Self.backgroundInterval(
            spentSinceAnchor: projectionByAccount[account.id]?.spentSinceAnchor,
            lastPrimaryDelta: lastPrimaryDelta[account.id],
            windowResetAt: lastGood[account.id]?.primary.resetAt,
            screenLocked: screenLocked,
            networkFailures: networkFailureStreak[account.id] ?? 0,
            now: now
        )
    }

    // MARK: - Between-poll projection

    /// Vendors whose completed calls the collector records per account identity.
    /// Grok and Antigravity have folder scopes only — never project from those.
    nonisolated static let projectableVendors: Set<VendorID> = ["claude", "codex"]

    /// A fresh API sample is the truth. Re-anchor on it and drop whatever we drew.
    private func anchorProjection(accountID: AccountID, snapshot: UsageSnapshot, now: Date) {
        guard let account = accountStore.accounts.first(where: { $0.id == accountID }),
              Self.projectableVendors.contains(account.vendorID)
        else { return }
        var projection = projectionByAccount[accountID] ?? UsageProjection()
        projection.anchor(
            fraction: snapshot.primary.usedFraction,
            resetAt: snapshot.primary.resetAt,
            at: now
        )
        projectionByAccount[accountID] = projection
    }

    /// Fit any pending rate, then extend each ring by the spend captured since its
    /// anchor. All SQLite work happens off the main actor.
    private func refreshProjections() async {
        guard !systemAsleep else { return }
        let targets = accountStore.accounts.filter {
            Self.projectableVendors.contains($0.vendorID) && projectionByAccount[$0.id] != nil
        }
        guard !targets.isEmpty else { return }

        let now = Date()
        var queries: [(id: AccountID, provider: VendorID, identity: String, learnFrom: Date?, anchorAt: Date)] = []
        for account in targets {
            guard let projection = projectionByAccount[account.id] else { continue }
            let identity: String
            if let cached = projectionIdentity[account.id] {
                identity = cached
            } else if let resolved = AccountUsageReader.identity(
                provider: account.vendorID,
                home: CredentialStore.directoryURL(for: account.credentialRef)
            ) {
                projectionIdentity[account.id] = resolved
                identity = resolved
            } else {
                continue
            }
            queries.append((
                id: account.id,
                provider: account.vendorID,
                identity: identity,
                learnFrom: projection.pendingPreviousAt,
                anchorAt: projection.anchorAt
            ))
        }
        guard !queries.isEmpty else { return }

        typealias Read = (learn: Double?, since: Double?, anchorAt: Date, learnFrom: Date?)
        let reads = await Task.detached(priority: .utility) { () -> [AccountID: Read] in
            var out: [AccountID: Read] = [:]
            for query in queries {
                let learn = query.learnFrom.flatMap {
                    AccountUsageReader.capturedDollars(
                        provider: query.provider,
                        identity: query.identity,
                        from: $0,
                        to: query.anchorAt
                    )
                }
                let since = AccountUsageReader.capturedDollars(
                    provider: query.provider,
                    identity: query.identity,
                    from: query.anchorAt,
                    to: now
                )
                out[query.id] = (learn: learn, since: since, anchorAt: query.anchorAt, learnFrom: query.learnFrom)
            }
            return out
        }.value

        var changed = false
        for (id, read) in reads {
            guard var projection = projectionByAccount[id] else { continue }
            let before = projection.projected
            // A poll may have re-anchored during the await; then this read is stale.
            guard projection.applyRead(
                learn: read.learn,
                since: read.since,
                anchorAt: read.anchorAt,
                learnFrom: read.learnFrom,
                now: now
            ) else { continue }
            projectionByAccount[id] = projection
            if abs((projection.projected ?? 0) - (before ?? 0)) > 1e-6 { changed = true }
        }
        if changed { rebuildWidgets() }
    }

    // MARK: - View models

    /// Drop cooldown keys that have elapsed so the account can be scheduled again.
    /// Does **not** clear `lastError` — that waits for a successful fetch.
    private func expireCooldowns(now: Date) {
        for (id, until) in cooldownUntil where until <= now {
            cooldownUntil[id] = nil
        }
    }

    private func rebuildWidgets() {
        expireCooldowns(now: Date())
        let mode = preferences.displayMode
        let next = accountStore.accounts.map { account in
            makeViewModel(account: account, mode: mode)
        }
        // Every assignment re-renders SwiftUI observers; most ticks change nothing.
        if next != widgets { widgets = next }
        rebuildFetchStatuses()
    }

    private func rebuildFetchStatuses() {
        let now = Date()
        let statuses: [AccountFetchStatus] = accountStore.accounts.map { account in
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
                    outcome = .failure(Self.caption(for: err, vendorID: account.vendorID) ?? "waiting to retry")
                } else {
                    outcome = .failure("cooling down")
                }
            } else if attempt == nil {
                outcome = .never
            } else if let err {
                outcome = .failure(Self.caption(for: err, vendorID: account.vendorID) ?? "waiting to retry")
            } else {
                outcome = .success
            }

            let minPoll = TimeInterval(
                VendorRegistry.adapter(for: account.vendorID)?.minPollSeconds ?? 300
            )
            let interval = max(backgroundInterval(for: account, now: now), minPoll)
            let nextDue: Date?
            if let cool, cool > now {
                nextDue = cool
            } else if let attempt {
                nextDue = min(attempt.addingTimeInterval(interval), retryDueAt[account.id] ?? .distantFuture)
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
        if statuses != fetchStatuses { fetchStatuses = statuses }
        let budget = Self.estimateBudgetCaption(accounts: accountStore.accounts)
        if budget != budgetCaption { budgetCaption = budget }
    }

    /// Rough **worst case** for background traffic: every account burning at once.
    /// Idle accounts cost a fifteenth of this, and expand is extra, on demand.
    nonisolated static func estimateBudgetCaption(accounts: [Account]) -> String {
        guard !accounts.isEmpty else { return "" }
        var perHour = 0.0
        for account in accounts {
            let minPoll = Double(VendorRegistry.adapter(for: account.vendorID)?.minPollSeconds ?? 300)
            let interval = max(activePollSeconds, minPoll)
            let weight = account.vendorID == "grok" ? 1.15 : 1.0
            perHour += weight * (3600.0 / interval)
        }
        let n = Int(perHour.rounded(.up))
        return String(localized: "≤\(n) API calls/h all busy · 1m busy / 15m idle · \(accounts.count) acct")
    }

    private func makeViewModel(
        account: Account,
        mode: PreferencesStore.DisplayMode
    ) -> WidgetViewModel {
        let snap = lastGood[account.id]
        let usedPrimary = snap?.primary.usedFraction ?? 0
        let usedSecondary = snap?.secondary?.usedFraction
        let usedTertiary = snap?.tertiary?.usedFraction

        let primaryFraction = Self.displayFraction(used: usedPrimary, mode: mode)
        let secondaryFraction = usedSecondary.map {
            Self.displayFraction(used: $0, mode: mode)
        }
        let tertiaryFraction = usedTertiary.map {
            Self.displayFraction(used: $0, mode: mode)
        }

        let burn = burnByAccount[account.id]?.current
            ?? BurnRate(ratio: 0, sampleCount: 0)
        // lastGood is error-free only; errors live in lastError.
        let err = lastError[account.id]
        // No good sample → skeleton (not fake 0%), even when a soft error caption shows.
        let awaiting = snap == nil || snap?.primary.isReported == false
        let notice = lastNotice[account.id] ?? snap?.notice
        let burnSource = burnSourceByAccount[account.id] ?? .none
        let service = VendorStatusStore.shared.snapshot(for: account.vendorID)
        let healthPair = AccountHealth.resolve(
            error: err,
            notice: awaiting ? nil : notice,
            awaitingFirst: awaiting,
            service: service,
            authCaption: Self.caption(for: err, vendorID: account.vendorID)
        )

        let shortCaption = Self.caption(for: err, vendorID: account.vendorID)
        let detail = Self.detailCaption(
            for: err,
            vendorID: account.vendorID,
            credentialRef: account.credentialRef
        ) ?? (awaiting ? nil : notice)
        let checkedAt = lastFetchAt[account.id]
        let successAt = lastSuccessAt[account.id]
        let cool = cooldownUntil[account.id]
        let retryAt = cool.flatMap { $0 > Date() ? $0 : nil }
        // Only extend a ring we actually have. A skeleton must stay a skeleton.
        let projected = (awaiting ? nil : projectionByAccount[account.id]?.projected)
            .map { Self.displayFraction(used: $0, mode: mode) }

        return WidgetViewModel(
            usageSnapshot: snap,
            id: account.id,
            title: account.label,
            vendorID: account.vendorID,
            tint: Self.tint(for: account.vendorID),
            primaryFraction: awaiting ? 0 : primaryFraction,
            secondaryFraction: awaiting ? nil : secondaryFraction,
            tertiaryFraction: awaiting ? nil : tertiaryFraction,
            usedPrimaryFraction: usedPrimary,
            centerPercent: awaiting ? 0 : Int((primaryFraction * 100).rounded()),
            burnRatio: awaiting ? 0 : burn.ratio,
            burnSource: awaiting ? .none : burnSource,
            burnLongRatio: awaiting ? 0 : burn.longRatio,
            burnSampleAt: awaiting ? nil : burn.lastSampleAt,
            burnQuantized: awaiting ? false : burn.quantized,
            hoverWindows: awaiting
                ? [HoverWindowLine(label: "…", usage: "waiting for first poll", resetAt: nil)]
                : Self.hoverWindows(snapshot: snap, mode: mode),
            errorCaption: shortCaption,
            detailCaption: detail,
            noticeCaption: awaiting ? nil : notice,
            lastCheckedAt: checkedAt,
            lastSuccessAt: successAt,
            retryAt: retryAt,
            isAwaitingFirstSample: awaiting,
            health: healthPair.health,
            healthTooltip: healthPair.tooltip,
            projectedPrimaryFraction: projected,
            needsReauth: err == .authRequired
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
        case "agy": return .agy
        default: return .neutral
        }
    }

    /// Short under-widget line (truncated by the cell).
    nonisolated static func caption(for error: UsageError?, vendorID: VendorID = "") -> String? {
        guard let error else { return nil }
        switch error {
        case .authRequired:
            switch vendorID {
            case "claude": return String(localized: "reconnect account")
            case "codex": return String(localized: "reauth: codex")
            case "grok": return String(localized: "reauth: grok")
            case "agy": return String(localized: "reauth: agy")
            default: return String(localized: "reauth needed")
            }
        case .rateLimited:
            return vendorID == "claude" ? String(localized: "oauth rate limited") : String(localized: "rate limited")
        case .network(let message):
            return message.isEmpty ? String(localized: "network error") : message
        case .parse(let message):
            return message.isEmpty ? String(localized: "parse error") : message
        case .unavailable:
            // One classification (UnavailableReason) for severity and copy (core-10).
            switch error.unavailableReason ?? .temporary {
            case .needsLogin: return String(localized: "need browser login")
            // Self-scheduled retry: rings stay, no red line. Notice/tooltip carry the age.
            case .refreshPending: return nil
            case .tokenQuiet, .temporary: return String(localized: "token quiet")
            }
        }
    }

    /// The one command that signs this account in again from a terminal.
    nonisolated static func loginCommand(vendorID: VendorID, home: String) -> String {
        switch vendorID {
        case "claude": return "CLAUDE_CONFIG_DIR='\(home)' claude auth login --claudeai"
        case "codex": return "CODEX_HOME='\(home)' codex login"
        case "grok": return "GROK_HOME='\(home)' grok login --oauth"
        case "agy": return "HOME='\(home)' agy"
        default: return ""
        }
    }

    /// Full explanation for the downward hover tooltip.
    nonisolated static func detailCaption(
        for error: UsageError?,
        vendorID: VendorID,
        credentialRef: CredentialRef
    ) -> String? {
        guard let error else { return nil }
        let home = CredentialStore.directoryURL(for: credentialRef).path
        switch error {
        case .authRequired:
            switch vendorID {
            case "claude":
                return String(localized: """
                Claude rejected this account’s token (invalid login or missing user:profile).
                setup-token cannot read usage — use full browser OAuth.
                Widget menu → Reauthenticate this account only (other accounts stay put).
                Or: CLAUDE_CONFIG_DIR='\(home)' claude auth login --claudeai
                """)
            case "codex":
                return String(localized: """
                Codex session rejected. Widget menu → Reauthenticate, or:
                CODEX_HOME='\(home)' codex login
                """)
            case "grok":
                return String(localized: """
                Grok session rejected. Widget menu → Reauthenticate, or:
                GROK_HOME='\(home)' grok login --oauth
                """)
            case "agy":
                return String(localized: """
                Antigravity session rejected. Widget menu → Reauthenticate, or:
                HOME='\(home)' agy
                """)
            default:
                return String(localized: "Reauthenticate from the widget menu.")
            }
        case .rateLimited:
            if vendorID == "claude" {
                return String(localized: """
                Claude OAuth token host is rate-limited (not your 5h/wk usage quota).
                Long quiet window — last-good rings stay. No re-login required yet.
                Each account uses its own credentials file; reconnect only if this never recovers.
                """)
            }
            return String(localized: """
            Vendor rate-limited (usage API or OAuth token refresh).
            Long quiet window; last-good numbers stay on the rings. No re-login needed yet.
            """)
        case .network(let message):
            return message.isEmpty
                ? String(localized: "Network error — will retry on next poll. Last-good rings stay if present.")
                : message
        case .parse(let message):
            return message.isEmpty ? String(localized: "Could not parse vendor response.") : message
        case .unavailable(let message):
            switch error.unavailableReason ?? .temporary {
            case .needsLogin:
                return String(localized: """
                \(message)
                Widget menu → Reauthenticate (browser login for this account only).
                \(loginCommand(vendorID: vendorID, home: home))
                """)
            case .refreshPending:
                return String(localized: """
                \(message)
                Soft failure — will retry on the next poll. Last-good rings stay if present.
                """)
            case .tokenQuiet, .temporary:
                return String(localized: """
                \(message.isEmpty ? String(localized: "Temporarily unavailable.") : message)
                Soft failure: last-good usage stays on the rings. Not a full reconnect yet.
                If this persists for hours, widget menu → Reauthenticate this account only.
                """)
            }
        }
    }

    /// Relative age: `3m ago`, `2h ago`, `1d ago`.
    nonisolated static func formatAgeAgo(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let total = Int(seconds.rounded(.down))
        if total < 60 { return String(localized: "<1m ago") }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let mins = (total % 3_600) / 60
        if days > 0 {
            return hours > 0 ? String(localized: "\(days)d \(hours)h ago") : String(localized: "\(days)d ago")
        }
        if hours > 0 {
            return mins > 0 ? String(localized: "\(hours)h \(mins)m ago") : String(localized: "\(hours)h ago")
        }
        return String(localized: "\(mins)m ago")
    }

    /// Compact age for under-widget captions: `3m`, `2h`, `1d`.
    nonisolated static func formatCompactAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let total = Int(seconds.rounded(.down))
        if total < 60 { return String(localized: "<1m") }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let mins = (total % 3_600) / 60
        if days > 0 { return String(localized: "\(days)d") }
        if hours > 0 { return String(localized: "\(hours)h") }
        return String(localized: "\(mins)m")
    }

    /// Freshness line for a healthy widget. Without this a 14-minute-old ring and
    /// a one-second-old ring look identical, which is what made the numbers feel
    /// wrong long before the poll interval was the suspect.
    /// `projectedFraction` is already display-mode mapped, so this line agrees with
    /// the usage rows above it instead of quietly reporting Used inside Remaining.
    nonisolated static func formatFreshnessLine(
        lastSuccessAt: Date?,
        projectedFraction: Double?,
        now: Date = Date()
    ) -> String? {
        guard let lastSuccessAt else { return nil }
        let age = formatAgeAgo(since: lastSuccessAt, now: now)
        guard let projectedFraction else { return String(localized: "checked \(age)") }
        let percent = Int((min(1, max(0, projectedFraction)) * 100).rounded())
        return String(localized: "checked \(age) · ≈\(percent)% est. from local calls")
    }

    /// Timing lines for error tips: checked / retry / last ok.
    nonisolated static func formatErrorTimingLines(
        lastCheckedAt: Date?,
        lastSuccessAt: Date?,
        retryAt: Date?,
        now: Date = Date()
    ) -> [String] {
        var lines: [String] = []
        if let checked = lastCheckedAt {
            lines.append(String(localized: "checked \(formatAgeAgo(since: checked, now: now))"))
        }
        if let retry = retryAt, retry > now,
           let remaining = formatResetRemaining(until: retry, now: now)
        {
            lines.append(String(localized: "retry in \(remaining)"))
        } else if lastCheckedAt != nil, retryAt == nil {
            lines.append(String(localized: "retry on next poll"))
        }
        if let ok = lastSuccessAt {
            lines.append(String(localized: "last ok \(formatAgeAgo(since: ok, now: now))"))
        }
        return lines
    }

    /// Hover rows: primary + secondary + tertiary rings, then remaining extras.
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
        if let tertiary = snapshot.tertiary {
            lines.append(windowLine(window: tertiary, mode: mode))
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
        if seconds <= 0 { return String(localized: "now") }
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let mins = (total % 3_600) / 60
        if days > 0 {
            return hours > 0 ? String(localized: "\(days)d \(hours)h") : String(localized: "\(days)d")
        }
        if hours > 0 {
            return mins > 0 ? String(localized: "\(hours)h \(mins)m") : String(localized: "\(hours)h")
        }
        if mins > 0 { return String(localized: "\(mins)m") }
        return String(localized: "<1m")
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
