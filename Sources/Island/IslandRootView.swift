import AppKit
import SwiftUI

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var orchestrator = UsageOrchestrator.shared
    @ObservedObject private var preferences = PreferencesStore.shared

    @State private var showPrefs = false
    @State private var collapseTask: Task<Void, Never>?

    /// Rim sits this many points outside the black notch fill so L/R flanks
    /// clear the hardware bezel and read against the menu bar.
    private let rimOutset: CGFloat = 1.25

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
        .onHover { handleHover($0) }
        .sheet(isPresented: $showPrefs) {
            PrefsSheet(preferences: preferences)
        }
        .onChange(of: showPrefs) { open in
            if open {
                collapseTask?.cancel()
                model.setState(.expanded)
            } else if model.state == .expanded {
                scheduleCollapse()
            }
        }
    }

    // MARK: - Compact

    private var compactNotchRim: some View {
        let nw = model.notch.width
        let nh = model.notch.height
        let radius = cornerRadius(forHeight: nh)
        // Rim path is outset so left/right flanks are outside the camera black.
        let rimW = nw + rimOutset * 2
        let rimH = nh + rimOutset

        return ZStack(alignment: .top) {
            // Hardware dead-zone fill — exact notch size, pure black, no shadow.
            IslandShape(bottomRadius: radius)
                .fill(Color.black)
                .frame(width: nw, height: nh)
                .frame(width: rimW, height: rimH, alignment: .top)

            // Hairline U: left + bottom + right, outside the fill.
            NotchRimPath(bottomRadius: radius + rimOutset * 0.35)
                .stroke(
                    rimGradient,
                    style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
                )
                .frame(width: rimW, height: rimH)
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
        .contentShape(Rectangle())
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
