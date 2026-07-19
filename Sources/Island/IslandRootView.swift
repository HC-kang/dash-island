import AppKit
import SwiftUI

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var orchestrator = UsageOrchestrator.shared
    @ObservedObject private var preferences = PreferencesStore.shared

    @State private var showPrefs = false
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            if model.state == .expanded {
                expandedBody
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                compactBody
                    .transition(.opacity)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.state)
        .onHover { hovering in
            handleHover(hovering)
        }
        .sheet(isPresented: $showPrefs) {
            PrefsSheet(preferences: preferences)
        }
        // Keep expanded while prefs sheet is open.
        .onChange(of: showPrefs) { open in
            if open {
                collapseTask?.cancel()
                model.setState(.expanded)
            } else if model.state == .expanded {
                scheduleCollapse()
            }
        }
    }

    // MARK: - Compact (default)

    private var compactBody: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 5, height: 5)
            Text(compactLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black)
        )
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            collapseTask?.cancel()
            model.setState(.expanded)
        }
        .accessibilityLabel("Dash Island")
        .accessibilityHint("Hover or click to show usage")
    }

    private var compactLabel: String {
        if DemoWidgets.isForced {
            return "Demo"
        }
        let n = accountStore.accounts.count
        if n == 0 { return "Dash" }
        return n == 1 ? "1 account" : "\(n) accounts"
    }

    // MARK: - Expanded

    private var expandedBody: some View {
        ZStack(alignment: .bottomLeading) {
            GaugeClusterView(
                widgets: widgets,
                accountCount: accountStore.accounts.count,
                showEmptyAdd: showEmptyAdd,
                showEdgeChrome: showEdgeChrome
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .padding(.bottom, 52)

            PrefsGearButton {
                NSApp.activate(ignoringOtherApps: true)
                showPrefs = true
            }
            .padding(.leading, 10)
            .padding(.bottom, 56)
        }
        .background(islandBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var islandBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 26,
            bottomTrailingRadius: 26,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
    }

    private var widgets: [WidgetViewModel] {
        if DemoWidgets.isForced {
            return DemoWidgets.make()
        }
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

    // MARK: - Hover

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
