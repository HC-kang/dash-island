import AppKit
import SwiftUI

/// Dark preferences content hosted in `PrefsWindowController` (not a sheet).
struct PrefsSheet: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject private var launchAtLogin = LaunchAtLoginStore.shared
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preferences")
                    .font(Typography.settingsTitle)
                    .foregroundStyle(.white)
                Spacer()
                Button("Done", action: onDone)
                    .font(Typography.settingsRow)
                    .foregroundStyle(.white.opacity(0.75))
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            hairline

            VStack(alignment: .leading, spacing: 16) {
                prefBlock(title: "DISPLAY") {
                    segmented(
                        selection: $preferences.displayMode,
                        options: [
                            (.used, "Used"),
                            (.remaining, "Remaining")
                        ]
                    )
                }

                prefBlock(title: "UPDATES") {
                    Text("Background poll every 15m · fresh data when you expand the island.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                prefBlock(title: "GENERAL") {
                    Toggle(isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )) {
                        Text("Launch at Login")
                            .font(Typography.settingsRow)
                            .foregroundStyle(.white.opacity(0.88))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(IslandColor.liveTeal)

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
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)

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
            .padding(.vertical, 14)
        }
        .frame(width: 320, height: 300)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { launchAtLogin.refresh() }
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
