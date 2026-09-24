import AppKit
import SwiftUI

@MainActor
final class UsageDetailPanel: NSWindowController, NSWindowDelegate {
    static let shared = UsageDetailPanel()
    private(set) var isOpen = false
    private var displayedAccountID: AccountID?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Bumped by every show/close so a fade-out that finishes late does not
    /// hide a panel that was reopened meanwhile.
    private var fadeToken = 0
    /// The panel drops this far from under the island while it fades in.
    private static let slide: CGFloat = 10

    private init() {
        let panel = DetailWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 620),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        // Cmd-Tab away hides the panel without a click for the outside monitor;
        // close it so `isOpen` does not hold the island expanded.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let details = UsageDetailPanel.shared
                if details.isOpen { details.close() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func toggle(model: WidgetViewModel) {
        if isOpen && displayedAccountID == model.id { close() }
        else { show(model: model) }
    }

    func show(model: WidgetViewModel) {
        guard let window else { return }
        displayedAccountID = model.id
        window.title = "\(model.title) usage"
        window.contentViewController = NSHostingController(rootView: UsageDetailView(initial: model).id(model.id))
        fadeToken += 1
        let wasVisible = window.isVisible && isOpen
        var target = window.frame
        let screen = DisplayInfo.currentScreen() ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let notch = NotchInfo.detect(from: screen)
            let top = min(visible.maxY, screen.frame.maxY - notch.height - 136 - 8)
            let height = min(720, max(280, top - visible.minY))
            let width = min(400, visible.width)
            let x = min(max(notch.anchoredCenterX - width / 2, visible.minX), visible.maxX - width)
            target = NSRect(x: x, y: max(visible.minY, top - height), width: width, height: height)
        }
        if !isOpen {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // The widget handles this click on mouse-up. Closing on mouse-down
                // first would make its toggle immediately reopen the same panel.
                if event.type == .leftMouseDown, event.window is BorderlessFloatingWindow { return event }
                // A confirmation raised from the panel (reset) is not an outside click.
                if event.window === IslandDialogController.shared.window { return event }
                if event.window !== self?.window { self?.close() }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // When the app is not active, a click on the island arrives here
                // too. Closing then made the widget's toggle reopen the panel.
                let left = event.type == .leftMouseDown
                let point = NSEvent.mouseLocation
                Task { @MainActor in
                    if !(left && Self.islandContains(point)) { self?.close() }
                }
            }
        }
        isOpen = true
        NotificationCenter.default.post(name: .dashIslandDetailsOpenChanged, object: true)
        NSApp.activate(ignoringOtherApps: true)
        guard !wasVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(target, display: true)
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.alphaValue = 0
        window.setFrame(target.offsetBy(dx: 0, dy: Self.slide), display: false)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            window.animator().alphaValue = 1
            window.animator().setFrame(target, display: true)
        }
    }

    private static func islandContains(_ point: NSPoint) -> Bool {
        NSApp.windows.contains { $0 is BorderlessFloatingWindow && $0.isVisible && $0.frame.contains(point) }
    }

    override func close() {
        guard let window, isOpen, window.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            clear()
            super.close()
            return
        }
        // Monitors and the island state release now; the content stays mounted
        // until the fade ends so the panel does not empty before it disappears.
        clear(unmount: false)
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(window.frame.offsetBy(dx: 0, dy: Self.slide / 2), display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.fadeToken == token else { return }
                self.window?.contentViewController = nil
                self.window?.orderOut(nil)
                self.window?.alphaValue = 1
            }
        })
    }

    func windowWillClose(_ notification: Notification) { clear() }

    private func clear(unmount: Bool = true) {
        guard isOpen else { return }
        // Unmount the view: its 15 s `.task` reload otherwise keeps reading usage
        // history while the panel is closed. `show` builds a fresh view.
        if unmount { window?.contentViewController = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        isOpen = false
        displayedAccountID = nil
        NotificationCenter.default.post(name: .dashIslandDetailsOpenChanged, object: false)
    }
}

private final class DetailWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { UsageDetailPanel.shared.close() }
}

extension Notification.Name {
    static let dashIslandDetailsOpenChanged = Notification.Name("dashIslandDetailsOpenChanged")
}

private struct UsageDetailView: View {
    let initial: WidgetViewModel
    @ObservedObject private var usage = UsageOrchestrator.shared
    @ObservedObject private var local = LocalUsageStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var preferences = PreferencesStore.shared
    @ObservedObject private var vendorStatus = VendorStatusStore.shared
    @ObservedObject private var quotaHistory = QuotaHistoryStore.shared
    @ObservedObject private var rates = ExchangeRateStore.shared
    @ObservedObject private var collector = CollectorUpdater.shared
    @ObservedObject private var resets = LimitResetCenter.shared
    @State private var period = UsagePeriod.today
    @State private var showAll = false
    @State private var expandedModels: Set<String> = []
    @State private var moreBelow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var activityLoading: Bool { local.loading.contains(liveTracking ? provider : sourceKey) }

    private var model: WidgetViewModel { usage.widgets.first { $0.id == initial.id } ?? initial }
    private var provider: String { initial.vendorID }
    private var liveTracking: Bool { ["codex", "claude"].contains(provider) }
    private var sourceKey: String { LocalUsageStore.sourceKey(provider: provider, accountID: initial.id) }
    private var providerName: String {
        ["claude": "Claude", "codex": "Codex", "grok": "Grok", "agy": "Antigravity"][provider] ?? provider
    }
    private var accent: Color {
        switch provider {
        case "claude": return IslandColor.claude
        case "grok": return IslandColor.grok
        case "agy": return IslandColor.agy
        default: return IslandColor.codex
        }
    }
    private var summary: LocalUsageSummary {
        LocalUsageSummary.make(events: local.snapshots[sourceKey]?.events ?? [], catalog: local.catalog, period: period)
    }
    private var windows: [WindowUsage] {
        guard let snapshot = model.usageSnapshot else { return [] }
        return ([snapshot.primary] + [snapshot.secondary, snapshot.tertiary].compactMap { $0 } + snapshot.extras)
            .filter(\.isReported)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        quotas
                        Divider().overlay(Color.white.opacity(0.05))
                        activity
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    // SwiftUI preferences do not leave the NSScrollView-backed ScrollView
                    // on macOS 13, so read the clip view directly.
                    .background(ScrollCueProbe { more in
                        if more != moreBelow { moreBelow = more }
                    })
                    Color.clear.frame(height: 0).id(Self.bottomAnchor)
                }
                // A connected mouse makes "Automatic" draw the legacy tracked scroller,
                // which clashes with the dark panel. Scrolling still works.
                .scrollIndicators(.never)
                .overlay(alignment: .bottom) {
                    if moreBelow { scrollCue(proxy) }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: moreBelow)
            }
        }
        .background(Color(white: 0.045))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .colorScheme(.dark)
        .tint(accent)
        .onAppear {
            _ = quotaHistory.history(for: initial.id)
            if preferences.displayCurrency == .krw { rates.refreshIfNeeded() }
            collector.updateIfOutdated()
            if let account = managedAccount { resets.load(account) }
        }
        .task(id: sourceKey) {
            repeat {
                await local.load(provider: provider, accountID: initial.id)
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
            } while !Task.isCancelled
        }
        .onChange(of: accounts.accounts.map(\.id)) { ids in
            if !ids.contains(initial.id) { UsageDetailPanel.shared.close() }
        }
    }

    private var managedAccount: Account? {
        accounts.accounts.first { $0.id == initial.id }
    }

    /// Reset credits: count, a Use button behind a confirmation, and the last outcome.
    private var resetRow: some View {
        let state = resets.offers[initial.id]
        let busy = resets.inFlight.contains(initial.id)
        let offer: LimitResetOffer? = { if case .ready(let o)? = state { return o }; return nil }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("Limit resets", systemImage: "arrow.counterclockwise")
                Spacer()
                switch state {
                case .ready(let o) where o.ineligibleReason != nil:
                    Text("Not available").foregroundStyle(.secondary)
                        .help(o.ineligibleReason.map { String(localized: "Vendor reason: \($0)") } ?? "")
                case .ready(let o):
                    Text("\(o.available) available").foregroundStyle(o.available > 0 ? accent : Color.secondary)
                case .loading:
                    Text("Checking…").foregroundStyle(.secondary)
                case .unavailable, nil:
                    Text("Unavailable").foregroundStyle(.secondary)
                }
                if let offer, offer.available > 0, offer.ineligibleReason == nil {
                    Button {
                        confirmReset(offer)
                    } label: {
                        if busy { ProgressView().controlSize(.mini) } else { Text("Use") }
                    }
                    .controlSize(.small)
                    .disabled(busy || !offer.canUse)
                    .help(offer.canUse ? "Spend one reset on this account" : "Available once a limit is full")
                }
            }
            .font(.system(size: 12, weight: .medium))
            if let expires = offer?.expiresAt, (offer?.available ?? 0) > 0 {
                Text("Use by \(expires.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(.ui)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let note = resets.notes[initial.id] {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.2), value: resets.notes[initial.id])
    }

    private func confirmReset(_ offer: LimitResetOffer) {
        guard let account = managedAccount else { return }
        let clears = offer.clears.map(Self.limitName).joined(separator: ", ")
        var lines = [String(localized: "Spends 1 of \(offer.available) resets on \(account.label). This cannot be undone.")]
        lines.append(clears.isEmpty
            ? String(localized: "The vendor resets the eligible usage limits now.")
            : String(localized: "Resets now: \(clears)."))
        let snap = model.usageSnapshot
        let highest = [snap?.primary.usedFraction, snap?.secondary?.usedFraction].compactMap { $0 }.max() ?? 0
        if offer.atLimit == false || (offer.atLimit == nil && highest < 1) {
            // Early use still spends the credit (the CLI asks the same way).
            lines.append(String(localized: "No limit is full right now: the highest is at \(Int((highest * 100).rounded()))%."))
        }
        let ok = IslandDialogController.shared.runConfirm(
            title: String(localized: "Use a limit reset?"),
            message: lines.joined(separator: " "),
            confirmTitle: String(localized: "Use reset"),
            isDestructive: true
        )
        if ok { resets.use(account, offer: offer) }
    }

    static func limitName(_ kind: String) -> String {
        switch kind {
        case "five_hour": return String(localized: "5-hour limit")
        case "seven_day": return String(localized: "weekly limit")
        case "seven_day_overage_included": return String(localized: "weekly extra usage")
        default: return kind.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            VendorLogoView(vendorID: provider, size: 25)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text([providerName, model.usageSnapshot?.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { UsageDetailPanel.shared.close() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Close details").accessibilityLabel("Close details")
        }
        .padding(24)
    }

    /// Vendor-side incident from the official status page, kept apart from account
    /// errors so "is it me or them?" has an answer.
    @ViewBuilder
    private var incidentBanner: some View {
        if let service = vendorStatus.byVendor[provider], service.level >= .degraded {
            Label(service.summary, systemImage: service.level == .outage ? "bolt.horizontal.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(service.level == .outage ? Color.red : Color.orange)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .help("From the vendor's public status page")
        }
    }

    private var quotas: some View {
        VStack(alignment: .leading, spacing: 15) {
            incidentBanner
            if let first = windows.first {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(shownPercent(first))%")
                        .font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(shownWord).font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                    Text(label(first)).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                }
                quotaBar(first)
                resetLabel(first).padding(.top, -8)
                trend(first)
                ForEach(Array(windows.dropFirst().enumerated()), id: \.offset) { _, window in
                    VStack(spacing: 6) {
                        HStack {
                            Text(label(window)).fontWeight(.medium)
                            Spacer()
                            Text("\(shownPercent(window))% \(shownWord)").monospacedDigit()
                        }.font(.system(size: 12))
                        quotaBar(window)
                        resetLabel(window)
                    }
                }
            } else {
                Text("Quota unavailable").font(.system(size: 22, weight: .medium))
                Text("No reading has been reported for this account.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if LimitResetCenter.resetter(for: provider) != nil { resetRow }
            if let error = model.errorCaption {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Color.orange)
            }
            ForEach([model.paceLine(now: Date())].compactMap { $0 }, id: \.self) { line in
                Label(line, systemImage: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.72))
            }
            if let date = model.lastSuccessAt {
                Text("Last quota reading \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .ui)))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ window: WindowUsage) -> String {
        let period: String
        switch window.kind {
        case .fiveHour: period = String(localized: "Session")
        case .weekly: period = String(localized: "Weekly")
        case .monthly: period = String(localized: "Monthly")
        case .unknown: period = String(localized: "Usage")
        }
        guard let name = window.labelOverride else { return period }
        return name.hasSuffix(" wk") ? String(localized: "\(String(name.dropLast(3))) Weekly") : name
    }

    /// Seven days of the headline window from QuotaHistory, in the display mode.
    @ViewBuilder
    private func trend(_ window: WindowUsage) -> some View {
        let now = Date()
        let span: TimeInterval = 7 * 86_400
        let points = (quotaHistory.byAccount[initial.id] ?? QuotaHistory())
            .series(window: window.displayLabel, days: 7, now: now)
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { g in
                    let xy: (QuotaHistory.Sample) -> CGPoint = { p in
                        let x = g.size.width * CGFloat(1 - now.timeIntervalSince(p.at) / span)
                        let v = showsUsed ? p.used : 1 - p.used
                        return CGPoint(x: x, y: g.size.height * CGFloat(1 - v))
                    }
                    let line = Path { path in
                        path.move(to: xy(points[0]))
                        for p in points.dropFirst() { path.addLine(to: xy(p)) }
                    }
                    ZStack {
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: g.size.height / 2))
                            p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2))
                        }
                        .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        Path { p in
                            p.addPath(line)
                            p.addLine(to: CGPoint(x: xy(points[points.count - 1]).x, y: g.size.height))
                            p.addLine(to: CGPoint(x: xy(points[0]).x, y: g.size.height))
                            p.closeSubpath()
                        }
                        .fill(accent.opacity(0.14))
                        line.stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        let end = xy(points[points.count - 1])
                        Circle().fill(accent).frame(width: 5, height: 5).position(end)
                    }
                }
                .frame(height: 36)
                HStack {
                    Text("7 days ago")
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.displayLabel) over the last 7 days")
        }
    }

    /// Follow the Used / Remaining preference, like the rings and the center number (ui-05).
    private var showsUsed: Bool { preferences.displayMode == .used }
    private var shownWord: String { showsUsed ? String(localized: "used") : String(localized: "left") }
    private func shownFraction(_ window: WindowUsage) -> Double {
        let used = min(1, max(0, window.usedFraction))
        return showsUsed ? used : 1 - used
    }
    private func shownPercent(_ window: WindowUsage) -> Int { Int((shownFraction(window) * 100).rounded()) }

    private func quotaBar(_ window: WindowUsage) -> some View {
        GeometryReader { proxy in
            Capsule().fill(Color.white.opacity(0.09))
                .overlay(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.9))
                        .frame(width: proxy.size.width * shownFraction(window))
                }
        }.frame(height: 5).accessibilityHidden(true)
    }

    private func resetLabel(_ window: WindowUsage) -> some View {
        HStack {
            if let date = window.resetAt {
                Text(date > Date() ? "Resets \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(.ui)))" : "Awaiting next reading")
            } else { Text("Reset time unavailable") }
            Spacer()
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var activity: some View {
        let summary = summary
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("This account")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if activityLoading { ProgressView().controlSize(.mini) }
                }
                Picker("Usage period", selection: $period) {
                    ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if liveTracking {
                    Text("Counts calls from CLI sessions started with tracking on. Restart older sessions to include them.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if summary.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activityLoading ? "Reading local usage…" : (liveTracking ? "No captured calls in this period" : "No account-linked activity in this period"))
                        .font(.system(size: 16, weight: .medium))
                    Text(liveTracking ? "Only calls linked to this account appear here."
                         : "Start the CLI with this account’s dedicated home to record its activity.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !liveTracking {
                        Button("Copy command for this account") {
                            let path = AccountUsageReader.directory.appendingPathComponent("account-cli").path
                            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(quoted + " " + initial.id.uuidString, forType: .string)
                        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent).padding(.top, 4)
                    }
                    if period != .month,
                       !LocalUsageSummary.make(events: local.snapshots[sourceKey]?.events ?? [], catalog: local.catalog, period: .month).models.isEmpty {
                        Button("View last 30 days") { period = .month }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent).padding(.top, 4)
                    }
                }.padding(.vertical, 8)
            } else {
                HStack(alignment: .top) {
                    metric(Self.tokens(summary.tokens.total), caption: liveTracking ? String(localized: "Captured tokens, incl. cache") : String(localized: "Tokens, including cache"))
                    Spacer()
                    metric(summary.dollars.map(money) ?? "—", caption: (provider == "grok" ? String(localized: "Recorded API value") : String(localized: "API estimate"))
                           + (summary.unpricedTokens > 0 ? String(localized: " · partial") : ""))
                }
                trend(summary.trend)
                VStack(spacing: 14) {
                    ForEach(showAll ? summary.models : Array(summary.models.prefix(3))) { row in
                        modelRow(row, total: summary.tokens.total)
                    }
                    if summary.models.count > 3 {
                        Button(showAll ? "Show less" : "Show all \(summary.models.count) models") { showAll.toggle() }
                            .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(accent)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                if let notice = local.snapshots[sourceKey]?.notice {
                    Text(notice).foregroundStyle(Color.orange)
                }
                if summary.unpricedTokens > 0 {
                    Text("\(Self.tokens(summary.unpricedTokens)) tokens have no model price.").foregroundStyle(Color.orange)
                }
                Text(liveTracking ? "Attributed by the account ID reported with each call. Earlier unlinked history is excluded."
                     : "Only records in this account’s local folder. Shared CLI activity is excluded.")
                if liveTracking {
                    let health = AccountUsageReader.collectorHealth()
                    if collector.status == .running {
                        Label("Updating the tracking collector…", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Color.secondary)
                    } else {
                        Label(health.message, systemImage: health.state == .active ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle")
                            .foregroundStyle(health.state == .active ? Color.secondary : Color.orange)
                    }
                    if case .failed(let reason) = collector.status {
                        Text(reason).foregroundStyle(Color.orange)
                    }
                    // Outdated updates itself (no CLI config change); only a first connection
                    // edits CLI configs, so that one waits for this click.
                    if health.state == .notConnected {
                        Button("Connect tracking") { collector.connect() }
                            .buttonStyle(.plain).foregroundStyle(accent)
                            .disabled(collector.status == .running)
                    } else if health.state == .outdated, collector.status != .running {
                        Button("Retry update") { collector.updateIfOutdated() }
                            .buttonStyle(.plain).foregroundStyle(accent)
                    }
                }
                if liveTracking, let date = local.snapshots[sourceKey]?.events.map(\.date).max() {
                    Text("Last captured call \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .ui)))")
                }
                Text(provider == "grok" ? "Values reported by Grok are not subscription charges."
                     : "API estimates use standard rates, not subscription charges.")
                if provider == "grok" {
                    Link("Grok cost reporting", destination: URL(string: "https://docs.x.ai/developers/cost-tracking")!)
                } else if provider == "agy" {
                    Link("Google API pricing · verified Sep 12, 2026", destination: URL(string: "https://ai.google.dev/gemini-api/docs/pricing")!)
                } else if let catalog = local.catalog {
                    Link("Price catalog · \(String(catalog.generatedAt.prefix(10)))", destination: LocalUsageStore.catalogURL)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metric(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func trend(_ points: [UsageTrendPoint]) -> some View {
        let peak = max(1, points.map(\.tokens).max() ?? 0)
        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(points) { point in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(point.tokens == 0 ? Color.white.opacity(0.06) : accent.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, 42 * Double(point.tokens) / Double(peak)))
                        .help("\(point.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .ui))) · \(Self.tokens(point.tokens)) tokens")
                }
            }.frame(height: 42, alignment: .bottom)
            HStack {
                Text(period == .today ? "00:00" : points.first?.date.formatted(.dateTime.month(.abbreviated).day().locale(.ui)) ?? "")
                Spacer()
                Text(period == .today ? "24:00" : "Today")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Usage over \(period.title)")
    }

    private func modelRow(_ row: ModelUsageTotal, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                if !expandedModels.insert(row.id).inserted { expandedModels.remove(row.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expandedModels.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).frame(width: 8)
                    Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.tokens(row.tokens.total)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(row.dollars.map { money($0) + (row.unpricedTokens > 0 ? "+" : "") } ?? "Unpriced")
                        .font(.system(size: 11)).lineLimit(1).frame(minWidth: 54, alignment: .trailing)
                }.monospacedDigit().contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(row.name), \(Self.tokens(row.tokens.total)) tokens, \(row.dollars.map(money) ?? "unpriced")")
                .accessibilityValue(expandedModels.contains(row.id) ? "Expanded" : "Collapsed")
                .accessibilityHint("Show input, output and cache tokens")
            GeometryReader { proxy in
                Capsule().fill(Color.white.opacity(0.05))
                    .overlay(alignment: .leading) {
                        Capsule().fill(accent.opacity(0.5)).frame(width: proxy.size.width * Double(row.tokens.total) / Double(max(1, total)))
                    }
            }.frame(height: 3).accessibilityHidden(true)
            if expandedModels.contains(row.id) {
                HStack(alignment: .top, spacing: 0) {
                    tokenPart("Input", row.tokens.input)
                    tokenPart("Output", row.tokens.output)
                    tokenPart("Cache write", row.tokens.cacheWrite)
                    tokenPart("Cache read", row.tokens.cacheRead)
                }.padding(.vertical, 5)
            }
        }
    }

    private func tokenPart(_ label: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(Self.tokens(value)).monospacedDigit()
        }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func tokens(_ count: Int64) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
    }
    private func money(_ amount: Double) -> String {
        CurrencyDisplay.format(usd: amount, currency: preferences.displayCurrency, krwPerUSD: rates.krwPerUSD)
    }
}

/// Reports whether the enclosing NSScrollView has content below the visible area.
/// Watches clip-view scrolling and document resizing (usage rows load late).
private struct ScrollCueProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView(onChange: onChange) }
    func updateNSView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil, let scroll = enclosingScrollView, let doc = scroll.documentView else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            doc.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            for (name, object) in [(NSView.boundsDidChangeNotification, scroll.contentView as NSView),
                                   (NSView.frameDidChangeNotification, doc)] {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let scroll = enclosingScrollView, let doc = scroll.documentView else { return }
            let visible = scroll.documentVisibleRect
            let below = doc.isFlipped ? doc.bounds.height - visible.maxY : visible.minY
            let more = IslandGeometry.hasMoreBelow(contentBottom: visible.height + below, viewportHeight: visible.height)
            // Frame-change notifications arrive mid-layout; SwiftUI drops state writes made
            // during a view update, so hand the result over on the next run-loop turn.
            DispatchQueue.main.async { [weak self] in self?.onChange(more) }
        }
    }
}

extension UsageDetailView {
    fileprivate static let bottomAnchor = "usageDetailBottom"

    /// Soft fade over the last line plus a quiet chevron; click scrolls to the end.
    /// Static on purpose: no idle animation (see MotionPolicy).
    @ViewBuilder
    fileprivate func scrollCue(_ proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(white: 0.045).opacity(0), Color(white: 0.045).opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 56)
            .allowsHitTesting(false)
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 44, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .accessibilityLabel("Scroll to more usage details")
        }
        .transition(.opacity)
    }
}
