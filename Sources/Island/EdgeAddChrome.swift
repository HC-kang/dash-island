import AppKit
import SwiftUI

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
        .frame(maxWidth: .infinity, minHeight: AccountWidget.cellHeight)
        .accessibilityLabel("Add account")
    }
}

// MARK: - Shared pieces

struct VendorMenuItems: View {
    var onSelect: (any VendorAdapter) -> Void

    var body: some View {
        // Product vendors only — Fake is never listed.
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
    private static var addTask: Task<Void, Never>?

    /// Run adapter `beginAdd` → name prompt → `AccountStore.add`.
    /// Cancel on progress or name dialog aborts and cleans credential folder.
    /// Claude uses **browser OAuth** (`claude auth login`) so the token has
    /// `user:profile` for `/api/oauth/usage`. Plain `setup-token` is model-only
    /// and Anthropic rejects it for usage with 403.
    static func beginAdd(adapter: any VendorAdapter) {
        activateForUI()
        addTask?.cancel()
        beginAddBrowserLogin(adapter: adapter)
    }

    private static func beginAddBrowserLogin(adapter: any VendorAdapter) {
        IslandDialogController.shared.showProgress(
            title: "Sign in",
            message: "Complete \(adapter.displayName) login in the browser or terminal. This window waits up to 3 minutes.",
            vendorID: adapter.id,
            onCancel: {
                addTask?.cancel()
                addTask = nil
            }
        )

        addTask = Task {
            var createdRef: CredentialRef?
            defer {
                IslandDialogController.shared.hideProgress()
                if Task.isCancelled, let ref = createdRef {
                    discardManagedFolder(ref: ref, vendorID: adapter.id)
                }
            }

            do {
                let result = try await adapter.beginAdd()
                createdRef = result.credentialRef
                if Task.isCancelled {
                    discardManagedFolder(ref: result.credentialRef, vendorID: adapter.id)
                    return
                }

                IslandDialogController.shared.hideProgress()

                let named = IslandDialogController.shared.runTextPrompt(
                    title: "Name this account",
                    message: "Label shown on the island. Cancel discards this sign-in.",
                    defaultValue: result.label,
                    confirmTitle: "Add",
                    vendorID: adapter.id
                )

                guard let named else {
                    discardManagedFolder(ref: result.credentialRef, vendorID: adapter.id)
                    return
                }

                var final = result
                final.label = named
                try AccountStore.shared.add(from: final)
            } catch is CancellationError {
            } catch let error as AccountStoreError where error == .maxAccountsReached {
                presentAlert(
                    title: "Account limit",
                    message: "You can add up to \(AccountStore.maxAccounts) accounts."
                )
            } catch {
                if !Task.isCancelled {
                    presentAlert(title: "Couldn’t add account", message: error.localizedDescription)
                }
            }
        }
    }

    static func rename(accountID: AccountID, currentLabel: String) {
        activateForUI()
        let vendorID = AccountStore.shared.accounts.first(where: { $0.id == accountID })?.vendorID
        guard let next = IslandDialogController.shared.runTextPrompt(
            title: "Rename",
            message: "Display name for this account on the island.",
            defaultValue: currentLabel,
            confirmTitle: "Save",
            vendorID: vendorID
        ) else { return }
        do {
            try AccountStore.shared.rename(id: accountID, label: next)
        } catch {
            presentAlert(title: "Couldn’t rename", message: error.localizedDescription)
        }
    }

    static func reauthenticate(account: Account) {
        activateForUI()
        guard let adapter = VendorRegistry.adapter(for: account.vendorID) else {
            presentAlert(
                title: "Reauthenticate",
                message: "No adapter for vendor “\(account.vendorID)”."
            )
            return
        }

        IslandDialogController.shared.showProgress(
            title: "Reauthenticate",
            message: account.vendorID == "claude"
                ? "Browser OAuth login required (needs user:profile for usage). setup-token alone is rejected by Anthropic. Completing login may take up to 3 minutes."
                : "Old credentials for this account were cleared. Complete a fresh \(adapter.displayName) sign-in in the browser (up to 3 minutes).",
            vendorID: adapter.id,
            onCancel: {
                addTask?.cancel()
                addTask = nil
            }
        )

        addTask?.cancel()
        addTask = Task {
            defer { IslandDialogController.shared.hideProgress() }
            do {
                let newRef = try await adapter.reauthenticate(account.credentialRef)
                if Task.isCancelled { return }
                try AccountStore.shared.markAuthenticated(id: account.id, credentialRef: newRef)
                UsageOrchestrator.shared.refresh(accountID: account.id)
            } catch is CancellationError {
                // ignored
            } catch {
                if !Task.isCancelled {
                    presentAlert(title: "Reauthenticate failed", message: error.localizedDescription)
                }
            }
        }
    }

    /// Confirm then delete. Safe to call from drag `onEnded` (deferred off gesture).
    static func remove(accountID: AccountID, label: String) {
        DispatchQueue.main.async {
            activateForUI()
            let ok = IslandDialogController.shared.runConfirm(
                title: "Remove \(label)?",
                message: "This removes the account from Dash Island and deletes its stored credentials.",
                confirmTitle: "Remove",
                isDestructive: true,
                showCancel: true
            )
            guard ok else { return }
            do {
                try AccountStore.shared.remove(id: accountID)
            } catch {
                presentAlert(title: "Couldn’t remove", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Alerts / activation

    /// Drop the managed folder. Vendor wipes leftover session files first.
    private static func discardManagedFolder(ref: CredentialRef, vendorID: VendorID) {
        let dir = CredentialStore.directoryURL(for: ref)
        switch vendorID {
        case "claude":
            ClaudeAdapter.clearManagedCredentials(configDir: dir)
        case "codex":
            CodexAdapter.clearManagedCredentials(codexHome: dir)
        case "grok":
            GrokAdapter.clearManagedCredentials(grokHome: dir)
        case "gemini":
            GeminiAdapter.clearManagedCredentials(home: dir)
        default:
            break
        }
        try? CredentialStore.removeDirectory(for: ref)
    }

    private static func presentAlert(title: String, message: String) {
        DispatchQueue.main.async {
            activateForUI()
            _ = IslandDialogController.shared.runConfirm(
                title: title,
                message: message,
                confirmTitle: "OK",
                isDestructive: false,
                showCancel: false
            )
        }
    }

    static func activateForUI() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .dashIslandRequestKey, object: nil)
    }
}
