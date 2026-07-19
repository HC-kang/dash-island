import AppKit
import SwiftUI

// MARK: - Right-edge dwell chrome

/// Low-contrast trailing chevron; after ≥500ms dwell, fades into a glass `+` menu.
/// Does **not** reserve layout width for an empty slot — overlays the island edge.
struct EdgeAddChrome: View {
    /// Called when the user picks a vendor from the add menu.
    var onSelectVendor: (any VendorAdapter) -> Void

    @State private var dwellTask: Task<Void, Never>?
    @State private var showPlus = false
    @State private var edgeHovered = false

    private static let dwellNanos: UInt64 = 500_000_000
    private static let stripWidth: CGFloat = 36
    private static let hitHeight: CGFloat = 88

    var body: some View {
        ZStack {
            if showPlus {
                vendorMenuButton
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                chevron
                    .transition(.opacity)
            }
        }
        .frame(width: Self.stripWidth, height: Self.hitHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            edgeHovered = hovering
            if hovering {
                startDwell()
            } else {
                cancelDwell(hidePlus: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add account")
    }

    private var chevron: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white.opacity(edgeHovered ? 0.38 : 0.22))
            .frame(width: Self.stripWidth, height: Self.hitHeight)
    }

    private var vendorMenuButton: some View {
        Menu {
            VendorMenuItems(onSelect: onSelectVendor)
        } label: {
            GlassPlusLabel()
        }
        .menuStyle(.borderlessButton)
        .frame(width: Self.stripWidth, height: Self.hitHeight)
    }

    private func startDwell() {
        dwellTask?.cancel()
        dwellTask = Task {
            try? await Task.sleep(nanoseconds: Self.dwellNanos)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                showPlus = true
            }
        }
    }

    private func cancelDwell(hidePlus: Bool) {
        dwellTask?.cancel()
        dwellTask = nil
        if hidePlus {
            withAnimation(.easeOut(duration: 0.14)) {
                showPlus = false
            }
        }
    }
}

// MARK: - Empty-state centered +

/// Single centered glass `+` when there are zero accounts (no dwell game).
struct CenteredAddButton: View {
    var onSelectVendor: (any VendorAdapter) -> Void

    var body: some View {
        Menu {
            VendorMenuItems(onSelect: onSelectVendor)
        } label: {
            GlassPlusLabel(size: 40, symbolSize: 16)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, minHeight: AccountWidget.cellSize + 8)
        .accessibilityLabel("Add account")
    }
}

// MARK: - Shared pieces

private struct VendorMenuItems: View {
    var onSelect: (any VendorAdapter) -> Void

    var body: some View {
        ForEach(VendorRegistry.all.map(\.id), id: \.self) { id in
            if let adapter = VendorRegistry.adapter(for: id) {
                Button(adapter.displayName) {
                    onSelect(adapter)
                }
            }
        }
    }
}

/// Quiet glass circle with a plus glyph.
struct GlassPlusLabel: View {
    var size: CGFloat = 28
    var symbolSize: CGFloat = 12

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.88))
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            }
            .contentShape(Circle())
    }
}

// MARK: - Add / manage helpers

@MainActor
enum AccountChromeActions {
    /// Run adapter `beginAdd` → `AccountStore.add` (orchestrator observes accounts).
    static func beginAdd(adapter: any VendorAdapter) {
        Task {
            do {
                let result = try await adapter.beginAdd()
                try AccountStore.shared.add(from: result)
            } catch let error as AccountStoreError where error == .maxAccountsReached {
                presentAlert(title: "Account Limit", message: "You can add up to \(AccountStore.maxAccounts) accounts.")
            } catch {
                presentAlert(title: "Couldn’t Add Account", message: error.localizedDescription)
            }
        }
    }

    static func rename(accountID: AccountID, currentLabel: String) {
        guard let next = promptText(
            title: "Rename Account",
            message: "Enter a new label for this account.",
            defaultValue: currentLabel,
            confirmTitle: "Rename"
        ) else { return }
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try AccountStore.shared.rename(id: accountID, label: trimmed)
        } catch {
            presentAlert(title: "Couldn’t Rename", message: error.localizedDescription)
        }
    }

    static func reauthenticate(account: Account) {
        guard let adapter = VendorRegistry.adapter(for: account.vendorID) else {
            presentAlert(title: "Reauthenticate", message: "No adapter for vendor “\(account.vendorID)”.")
            return
        }
        Task {
            do {
                let newRef = try await adapter.reauthenticate(account.credentialRef)
                try AccountStore.shared.markAuthenticated(id: account.id, credentialRef: newRef)
                UsageOrchestrator.shared.refresh(accountID: account.id)
            } catch {
                presentAlert(title: "Reauthenticate Failed", message: error.localizedDescription)
            }
        }
    }

    static func remove(accountID: AccountID, label: String) {
        let alert = NSAlert()
        alert.messageText = "Remove Account?"
        alert.informativeText = "“\(label)” will be removed. Credentials stored for this account will be deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AccountStore.shared.remove(id: accountID)
        } catch {
            presentAlert(title: "Couldn’t Remove", message: error.localizedDescription)
        }
    }

    // MARK: Alerts

    private static func promptText(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.isEditable = true
        field.isSelectable = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
