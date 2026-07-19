import AppKit
import SwiftUI

// MARK: - Prefs sheet

/// Thin preferences: display mode + poll interval only (no settings cathedral).
struct PrefsSheet: View {
    @ObservedObject var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Preferences")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Display")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Display", selection: $preferences.displayMode) {
                    Text("Used").tag(PreferencesStore.DisplayMode.used)
                    Text("Remaining").tag(PreferencesStore.DisplayMode.remaining)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Poll interval")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Poll interval", selection: $preferences.pollSeconds) {
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 300, height: 168)
    }
}

// MARK: - Quiet gear

/// Apple-quiet gear control that opens the prefs sheet.
struct PrefsGearButton: View {
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white.opacity(hovered ? 0.55 : 0.26))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background {
                    Circle()
                        .fill(Color.white.opacity(hovered ? 0.07 : 0))
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hovered = hovering
            }
        }
        .help("Preferences")
        .accessibilityLabel("Preferences")
    }
}
