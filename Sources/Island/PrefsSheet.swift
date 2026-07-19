import AppKit
import SwiftUI

/// Dark preferences content hosted in `PrefsWindowController` (not a sheet).
struct PrefsSheet: View {
    @ObservedObject var preferences: PreferencesStore
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

            LinearGradient(
                colors: [.clear, .white.opacity(0.06), .white.opacity(0.06), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 14)

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

                prefBlock(title: "POLL INTERVAL") {
                    segmented(
                        selection: $preferences.pollSeconds,
                        options: [
                            (300, "5 min"),
                            (900, "15 min"),
                            (1800, "30 min")
                        ]
                    )
                }
            }
            .padding(18)

            Spacer(minLength: 0)
        }
        .frame(width: 300, height: 200)
        .background(Color.black)
        .preferredColorScheme(.dark)
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
