import AppKit
import SwiftUI

// MARK: - Shared chrome (matches PrefsSheet)

/// Dark floating dialog shell — same language as Preferences.
struct IslandDialogChrome<Content: View>: View {
    let title: String
    var width: CGFloat = 320
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Typography.settingsTitle)
                .foregroundStyle(.white)
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

            content()
                .padding(18)
        }
        .frame(width: width)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Text prompt (rename / name on add)

struct IslandTextPromptView: View {
    let title: String
    let message: String
    let confirmTitle: String
    var vendorID: VendorID?
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var fieldFocused: Bool

    init(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String,
        vendorID: VendorID? = nil,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.vendorID = vendorID
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _text = State(initialValue: defaultValue)
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        IslandDialogChrome(title: title, width: 320) {
            VStack(alignment: .leading, spacing: 14) {
                if let vendorID {
                    HStack(spacing: 8) {
                        VendorLogoBadge(vendorID: vendorID)
                        Text(VendorRegistry.adapter(for: vendorID)?.displayName ?? vendorID)
                            .font(Typography.settingsRow)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                Text(message)
                    .font(Typography.settingsRow)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Label", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        fieldFocused
                                            ? Color.white.opacity(0.28)
                                            : Color.white.opacity(0.10),
                                        lineWidth: 1
                                    )
                            )
                    )
                    .focused($fieldFocused)
                    .onSubmit { submit() }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    dialogButton("Cancel", primary: false, destructive: false, action: onCancel)
                    dialogButton(
                        confirmTitle,
                        primary: true,
                        destructive: false,
                        enabled: canSubmit,
                        action: submit
                    )
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            fieldFocused = true
            // Select all so typing replaces the suggestion cleanly.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
                fieldFocused = true
            }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
    }
}

// MARK: - Progress (login wait)

struct IslandProgressView: View {
    let title: String
    let message: String
    var vendorID: VendorID? = nil
    let onCancel: () -> Void

    var body: some View {
        IslandDialogChrome(title: title, width: 320) {
            VStack(alignment: .leading, spacing: 16) {
                if let vendorID {
                    HStack(spacing: 8) {
                        VendorLogoBadge(vendorID: vendorID)
                        Text(VendorRegistry.adapter(for: vendorID)?.displayName ?? vendorID)
                            .font(Typography.settingsRow)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text(message)
                        .font(Typography.settingsRow)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer(minLength: 0)
                    dialogButton("Cancel", primary: false, destructive: false, action: onCancel)
                }
            }
        }
    }
}

// MARK: - Confirm / alert

struct IslandConfirmView: View {
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive: Bool = false
    var showCancel: Bool = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        IslandDialogChrome(title: title, width: 320) {
            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .font(Typography.settingsRow)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if showCancel {
                        dialogButton("Cancel", primary: false, destructive: false, action: onCancel)
                    }
                    dialogButton(
                        confirmTitle,
                        primary: true,
                        destructive: isDestructive,
                        action: onConfirm
                    )
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Buttons

@ViewBuilder
func dialogButton(
    _ title: String,
    primary: Bool,
    destructive: Bool,
    enabled: Bool = true,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Text(title)
            .font(Typography.settingsRow)
            .foregroundStyle(buttonForeground(primary: primary, destructive: destructive, enabled: enabled))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(buttonFill(primary: primary, destructive: destructive, enabled: enabled))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        buttonStroke(primary: primary, destructive: destructive),
                        lineWidth: 1
                    )
            )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.45)
}

private func buttonForeground(primary: Bool, destructive: Bool, enabled: Bool) -> Color {
    if destructive { return Color(red: 1, green: 0.55, blue: 0.52) }
    if primary { return .white.opacity(0.95) }
    return .white.opacity(0.7)
}

private func buttonFill(primary: Bool, destructive: Bool, enabled: Bool) -> Color {
    if destructive { return Color.red.opacity(0.18) }
    if primary { return Color.white.opacity(0.12) }
    return Color.white.opacity(0.04)
}

private func buttonStroke(primary: Bool, destructive: Bool) -> Color {
    if destructive { return Color.red.opacity(0.35) }
    if primary { return Color.white.opacity(0.16) }
    return Color.white.opacity(0.08)
}
