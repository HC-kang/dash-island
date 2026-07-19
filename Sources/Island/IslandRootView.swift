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

    // MARK: - Compact: hairline border on the hardware notch

    /// Solid black only in the physical notch dead zone (blends with glass),
    /// plus a *thin* gradient stroke along the U-edge — not a floating card.
    private var compactNotchRim: some View {
        let w = model.notch.width
        let h = model.notch.height
        let radius = cornerRadius(forHeight: h)

        return ZStack {
            // Exact notch fill — pure black, no material, no shadow.
            IslandShape(bottomRadius: radius)
                .fill(Color.black)

            // Hairline rim: left + bottom + right (open U). Top→bottom gradient so
            // vertical flanks stay visible (L→R gradient washed the sides out).
            NotchRimPath(bottomRadius: radius)
                .stroke(
                    rimGradient,
                    style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(width: w, height: h)
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

    // MARK: - Expanded chrome (panel under notch)

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
        // Hardware-ish continuous bottom corners scale with notch height.
        min(16, max(11, h * 0.40))
    }

    /// Top→bottom so left/right flanks share the same readable edge, brightest at the bottom curve.
    private var rimGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.28), location: 0),
                .init(color: Color.white.opacity(0.40), location: 0.45),
                .init(color: Color.white.opacity(0.62), location: 0.85),
                .init(color: Color.white.opacity(0.72), location: 1)
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
