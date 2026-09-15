import AppKit
import SwiftUI

@MainActor
final class UsageDetailPanel: NSWindowController, NSWindowDelegate {
    static let shared = UsageDetailPanel()
    private(set) var isOpen = false
    private var displayedAccountID: AccountID?
    private var localMonitor: Any?
    private var globalMonitor: Any?

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
        let screen = DisplayInfo.currentScreen() ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let notch = NotchInfo.detect(from: screen)
            let top = min(visible.maxY, screen.frame.maxY - notch.height - 136 - 8)
            let height = min(720, max(280, top - visible.minY))
            let width = min(400, visible.width)
            let x = min(max(notch.anchoredCenterX - width / 2, visible.minX), visible.maxX - width)
            window.setFrame(NSRect(x: x, y: max(visible.minY, top - height), width: width, height: height), display: true)
        }
        if !isOpen {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // The widget handles this click on mouse-up. Closing on mouse-down
                // first would make its toggle immediately reopen the same panel.
                if event.type == .leftMouseDown, event.window is BorderlessFloatingWindow { return event }
                if event.window !== self?.window { self?.close() }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
        isOpen = true
        NotificationCenter.default.post(name: .dashIslandDetailsOpenChanged, object: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    override func close() {
        clear()
        super.close()
    }

    func windowWillClose(_ notification: Notification) { clear() }

    private func clear() {
        guard isOpen else { return }
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
    @State private var period = UsagePeriod.today
    @State private var showAll = false
    @State private var expandedModels: Set<String> = []
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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    quotas
                    Divider().overlay(Color.white.opacity(0.05))
                    activity
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Color(white: 0.045))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .colorScheme(.dark)
        .tint(accent)
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

    private var quotas: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let first = windows.first {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(((1 - first.usedFraction) * 100).rounded()))%")
                        .font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("left").font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                    Text(label(first)).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                }
                quotaBar(first)
                resetLabel(first).padding(.top, -8)
                ForEach(Array(windows.dropFirst().enumerated()), id: \.offset) { _, window in
                    VStack(spacing: 6) {
                        HStack {
                            Text(label(window)).fontWeight(.medium)
                            Spacer()
                            Text("\(Int(((1 - window.usedFraction) * 100).rounded()))% left").monospacedDigit()
                        }.font(.system(size: 12))
                        quotaBar(window)
                        resetLabel(window)
                    }
                }
            } else {
                Text("Quota unavailable").font(.system(size: 22, weight: .medium))
                Text("No reading has been reported for this account.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if provider == "codex" {
                HStack {
                    Label("Rate limit resets", systemImage: "arrow.counterclockwise")
                    Spacer()
                    Text(model.usageSnapshot?.resetCreditsAvailable.map { "\($0) available" } ?? "Unavailable")
                        .foregroundStyle(model.usageSnapshot?.resetCreditsAvailable == nil ? Color.secondary : accent)
                }.font(.system(size: 12, weight: .medium))
            }
            if let error = model.errorCaption {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Color.orange)
            }
            if let date = model.lastSuccessAt {
                Text("Last quota reading \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ window: WindowUsage) -> String {
        let period: String
        switch window.kind {
        case .fiveHour: period = "Session"
        case .weekly: period = "Weekly"
        case .monthly: period = "Monthly"
        case .unknown: period = "Usage"
        }
        guard let name = window.labelOverride else { return period }
        return name.hasSuffix(" wk") ? String(name.dropLast(3)) + " Weekly" : name
    }

    private func quotaBar(_ window: WindowUsage) -> some View {
        GeometryReader { proxy in
            Capsule().fill(Color.white.opacity(0.09))
                .overlay(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.9))
                        .frame(width: proxy.size.width * min(1, max(0, 1 - window.usedFraction)))
                }
        }.frame(height: 5).accessibilityHidden(true)
    }

    private func resetLabel(_ window: WindowUsage) -> some View {
        HStack {
            if let date = window.resetAt {
                Text(date > Date() ? "Resets \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))" : "Awaiting next reading")
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
                    Text("Captured calls only. Reopen older Orca/CLI sessions to include their new usage.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if summary.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activityLoading ? "Reading local usage…" : (liveTracking ? "No captured calls in this period" : "No account-linked activity in this period"))
                        .font(.system(size: 16, weight: .medium))
                    Text(liveTracking ? "Only calls linked to this account appear here. Earlier unlinked history is excluded."
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
                    metric(Self.tokens(summary.tokens.total), caption: liveTracking ? "Captured tokens, incl. cache" : "Tokens, including cache")
                    Spacer()
                    metric(summary.dollars.map(Self.money) ?? "—", caption: (provider == "grok" ? "Recorded API value" : "API estimate")
                           + (summary.unpricedTokens > 0 ? " · partial" : ""))
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
                if liveTracking, let date = local.snapshots[sourceKey]?.events.map(\.date).max() {
                    Text("Last captured call \(date.formatted(date: .abbreviated, time: .shortened))")
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
                        .help("\(point.date.formatted()) · \(Self.tokens(point.tokens)) tokens")
                }
            }.frame(height: 42, alignment: .bottom)
            HStack {
                Text(period == .today ? "00:00" : points.first?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")
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
                    Text(row.dollars.map { Self.money($0) + (row.unpricedTokens > 0 ? "+" : "") } ?? "Unpriced")
                        .font(.system(size: 11)).lineLimit(1).frame(minWidth: 54, alignment: .trailing)
                }.monospacedDigit().contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(row.name), \(Self.tokens(row.tokens.total)) tokens, \(row.dollars.map(Self.money) ?? "unpriced")")
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
    private static func money(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
    }
}
