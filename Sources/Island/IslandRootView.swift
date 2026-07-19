import AppKit
import SwiftUI

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var orchestrator = UsageOrchestrator.shared
    @ObservedObject private var preferences = PreferencesStore.shared

    @State private var showPrefs = false
    @State private var collapseTask: Task<Void, Never>?

    /// Grow the black body this far past the aux-reported notch so the
    /// hairline rim sits *on* the body edge (no hollow gap to the desktop).
    private let bodyOutset: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            if model.state == .expanded {
                expandedChrome
                    .transition(.opacity)
                expandedContent
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else {
                compactNotchRim
                    .transition(.opacity)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.state)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.size.width)
        .onHover { handleHover($0) }
        .sheet(isPresented: $showPrefs) {
            PrefsSheet(preferences: preferences)
        }
        .onAppear { syncExpandedItemCount() }
        .onChange(of: accountStore.accounts.count) { _ in syncExpandedItemCount() }
        .onChange(of: orchestrator.widgets.count) { _ in syncExpandedItemCount() }
        .onChange(of: showPrefs) { open in
            if open {
                collapseTask?.cancel()
                model.setState(.expanded)
            } else if model.state == .expanded {
                scheduleCollapse()
            }
        }
    }

    /// 0 when empty-add; otherwise visible widget count (demo or live).
    private func syncExpandedItemCount() {
        if showEmptyAdd {
            model.setExpandedItemCount(0)
        } else {
            model.setExpandedItemCount(widgets.count)
        }
    }

    // MARK: - Compact

    private var compactNotchRim: some View {
        let nw = model.notch.width
        let nh = model.notch.height
        // Black body matches rim path exactly — fills the former hollow gap.
        let bodyW = nw + bodyOutset * 2
        let bodyH = nh + bodyOutset
        let radius = cornerRadius(forHeight: bodyH)

        return ZStack {
            // Solid black under the full U, including under the stroke.
            IslandShape(bottomRadius: radius)
                .fill(Color.black)

            // Hairline on the outer edge of that body (left + bottom + right).
            NotchRimPath(bottomRadius: radius)
                .stroke(
                    rimGradient,
                    style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(width: bodyW, height: bodyH)
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
        .contentShape(IslandShape(bottomRadius: radius))
        .onTapGesture {
            collapseTask?.cancel()
            model.setState(.expanded)
        }
        .accessibilityLabel("Dash Island")
        .accessibilityHint("Hover or click to show usage")
        .accessibilityValue(compactLabel)
    }

    // MARK: - Expanded

    private var expandedChrome: some View {
        let radius = cornerRadius(forHeight: model.notch.height)
        return IslandShape(bottomRadius: min(26, radius + 8))
            .fill(Color.black)
            .frame(width: model.size.width, height: model.blackHeight)
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private var expandedContent: some View {
        ZStack(alignment: .bottomLeading) {
            GaugeClusterView(
                widgets: widgets,
                accountCount: accountStore.accounts.count,
                showEmptyAdd: showEmptyAdd,
                showEdgeChrome: showEdgeChrome
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            PrefsGearButton {
                NSApp.activate(ignoringOtherApps: true)
                showPrefs = true
            }
            .padding(.leading, 10)
            .padding(.bottom, 10)
        }
        .padding(.top, model.notch.height)
        .frame(width: model.size.width, height: model.blackHeight, alignment: .top)
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
    }

    private func cornerRadius(forHeight h: CGFloat) -> CGFloat {
        min(16, max(11, h * 0.40))
    }

    /// Top→bottom keeps left/right flanks lit; brightest at the bottom curve.
    private var rimGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.38), location: 0),
                .init(color: Color.white.opacity(0.48), location: 0.4),
                .init(color: Color.white.opacity(0.68), location: 0.85),
                .init(color: Color.white.opacity(0.78), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var compactLabel: String {
        if DemoWidgets.isForced { return "Demo" }
        let n = accountStore.accounts.count
        if n == 0 { return "Dash Island" }
        return n == 1 ? "1 account" : "\(n) accounts"
    }

    private var widgets: [WidgetViewModel] {
        if DemoWidgets.isForced { return DemoWidgets.make() }
        return orchestrator.widgets
    }

    private var showEmptyAdd: Bool {
        !DemoWidgets.isForced && accountStore.accounts.isEmpty
    }

    private var showEdgeChrome: Bool {
        !DemoWidgets.isForced
            && accountStore.accounts.count > 0
            && accountStore.accounts.count < AccountStore.maxAccounts
    }

    private func handleHover(_ hovering: Bool) {
        if hovering {
            collapseTask?.cancel()
            collapseTask = nil
            model.setState(.expanded)
        } else if !showPrefs {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, !showPrefs else { return }
            model.setState(.compact)
        }
    }
}
