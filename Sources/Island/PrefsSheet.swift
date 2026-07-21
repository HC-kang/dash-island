import AppKit
import SwiftUI

/// Dark preferences content hosted in `PrefsWindowController` (not a sheet).
struct PrefsSheet: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject private var launchAtLogin = LaunchAtLoginStore.shared
    @ObservedObject private var targetDisplay = TargetDisplayStore.shared
    var onDone: () -> Void

    /// Leave room for traffic lights under transparent titlebar.
    private let titlebarPad: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — inset below close button; no competing "Done" chrome.
            HStack {
                Text("Preferences")
                    .font(Typography.settingsTitle)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, titlebarPad)
            .padding(.bottom, 12)

            hairline

            VStack(alignment: .leading, spacing: 18) {
                prefBlock(title: "DISPLAY MODE") {
                    segmented(
                        selection: $preferences.displayMode,
                        options: [
                            (.used, "Used"),
                            (.remaining, "Remaining")
                        ]
                    )
                }

                prefBlock(title: "RIM") {
                    rimSwatches(selection: $preferences.rimAccent)
                    Text("Neon edge glow (compact + expanded).")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.40))
                }

                prefBlock(title: "SCREEN") {
                    screenPicker
                    Text("Auto: notched if available. Follow cursor: island hops to the display under the mouse. Or pin a specific screen.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.40))
                        .fixedSize(horizontal: false, vertical: true)
                }

                prefBlock(title: "UPDATES") {
                    Text("Background poll every 15m · fresh data when you expand the island.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                prefBlock(title: "GENERAL") {
                    HStack {
                        Text("Launch at Login")
                            .font(Typography.settingsRow)
                            .foregroundStyle(.white.opacity(0.88))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .tint(IslandColor.liveTeal)
                    }

                    Button {
                        UsageOrchestrator.shared.refresh()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Refresh all accounts now")
                                .font(Typography.settingsRow)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            hairline

            HStack {
                Button("Quit Dash Island") {
                    onDone()
                    NSApp.terminate(nil)
                }
                .font(Typography.settingsRow)
                .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.52).opacity(0.9))
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(width: 340)
        .fixedSize(horizontal: true, vertical: true)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { launchAtLogin.refresh() }
    }

    private var screenPicker: some View {
        let displays = DisplayInfo.all()
        return VStack(alignment: .leading, spacing: 6) {
            screenRow(
                title: "Auto",
                subtitle: "Notched if available",
                selected: targetDisplay.choice == .auto
            ) {
                targetDisplay.choice = .auto
            }
            screenRow(
                title: "Follow cursor",
                subtitle: "Hops to the display under the mouse",
                selected: targetDisplay.choice == .followCursor
            ) {
                targetDisplay.choice = .followCursor
            }
            ForEach(displays, id: \.stableID) { info in
                let selected: Bool = {
                    if case .stable(let id) = targetDisplay.choice { return id == info.stableID }
                    return false
                }()
                let badge = [
                    info.isBuiltin ? "Built-in" : "External",
                    info.hasNotch ? "notch" : nil
                ].compactMap { $0 }.joined(separator: " · ")
                screenRow(
                    title: info.name,
                    subtitle: badge,
                    selected: selected
                ) {
                    targetDisplay.choice = .stable(id: info.stableID)
                }
            }
        }
    }

    private func screenRow(
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? IslandColor.liveTeal : Color.white.opacity(0.28))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.settingsRow)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.10 : 0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private var hairline: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.06), .white.opacity(0.06), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.horizontal, 14)
    }

    private func prefBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typography.settingsSection)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
    }

    private func rimSwatches(selection: Binding<PreferencesStore.RimAccent>) -> some View {
        HStack(spacing: 9) {
            ForEach(PreferencesStore.RimAccent.allCases) { accent in
                let selected = selection.wrappedValue == accent
                Button {
                    selection.wrappedValue = accent
                } label: {
                    Circle()
                        .fill(accent.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    Color.white.opacity(selected ? 0.95 : 0.15),
                                    lineWidth: selected ? 2.2 : 1
                                )
                        )
                        .shadow(color: accent.color.opacity(selected ? 0.85 : 0.35), radius: selected ? 6 : 3)
                }
                .buttonStyle(.plain)
                .help(accent.label)
                .accessibilityLabel(accent.label)
            }
        }
    }

    private func segmented<T: Hashable>(
        selection: Binding<T>,
        options: [(T, String)]
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let selected = selection.wrappedValue == opt.0
                Button {
                    selection.wrappedValue = opt.0
                } label: {
                    Text(opt.1)
                        .font(Typography.settingsRow)
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.45))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(selected ? 0.12 : 0))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}
