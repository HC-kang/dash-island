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
            // Black silhouette only — never fills the transparent tooltip tail.
            silhouette
                .frame(width: silhouetteWidth, height: model.blackHeight)
                .frame(maxWidth: .infinity, alignment: .top)

            if model.state == .expanded {
                expandedContent
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else {
                // Hit target + a11y over the notch silhouette (no hanging pill).
                Color.clear
                    .frame(width: silhouetteWidth, height: model.notch.height)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .contentShape(IslandShape(bottomRadius: cornerRadius))
                    .onTapGesture {
                        collapseTask?.cancel()
                        model.setState(.expanded)
                    }
                    .accessibilityLabel("Dash Island")
                    .accessibilityHint("Hover or click to show usage")
                    .accessibilityValue(compactLabel)
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

    // MARK: - Silhouette

    private var silhouetteWidth: CGFloat {
        model.state == .compact ? model.notch.width : model.size.width
    }

    private var cornerRadius: CGFloat {
        // Scale corner with notch height so the U tracks hardware curves.
        min(18, max(10, model.notch.height * 0.42))
    }

    private var silhouette: some View {
        let shape = IslandShape(bottomRadius: cornerRadius)
        return ZStack {
            shape.fill(Color.black)
            // Thin gradient outline wrapping the notch / island edge.
            shape
                .strokeBorder(outlineGradient, lineWidth: model.state == .compact ? 1.0 : 0.8)
                .opacity(model.state == .compact ? 0.95 : 0.35)
        }
        .shadow(color: .black.opacity(model.state == .expanded ? 0.45 : 0.25), radius: model.state == .expanded ? 18 : 6, y: 4)
    }

    /// Soft metal edge: brighter mid-bottom, fades at the top corners.
    private var outlineGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.08),
                Color.white.opacity(0.42),
                Color.white.opacity(0.55),
                Color.white.opacity(0.42),
                Color.white.opacity(0.08)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var compactLabel: String {
        if DemoWidgets.isForced { return "Demo" }
        let n = accountStore.accounts.count
        if n == 0 { return "Dash Island" }
        return n == 1 ? "1 account" : "\(n) accounts"
    }

    // MARK: - Expanded content (below notch dead zone)

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
        // Content starts under the physical notch — never under the dead pixels.
        .padding(.top, model.notch.height)
        .frame(width: model.size.width, height: model.blackHeight, alignment: .top)
        // Allow hover tooltips to paint into the transparent window overflow
        // below the black silhouette (no black gutter).
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
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

