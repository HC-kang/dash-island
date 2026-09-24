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
            // First run showed only a bare "+"; say what it does (ui-13). A borderless
            // Menu flattens its label to one line, so keep it to icon + text.
            Label("Add an account", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, minHeight: AccountWidget.cellHeight)
        .accessibilityLabel("Add account")
        .help("Add a Claude, Codex, Grok, or Antigravity account")
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
        beginAddBrowserLogin(adapter: adapter)
    }

    /// Cancel the running add/reauth and hand back its handle. The next task awaits
    /// it first, so the old cleanup (hideProgress, .prior restore, folder discard)
    /// cannot land on top of the new flow.
    private static func cancelRunning() -> Task<Void, Never>? {
        let previous = addTask
        previous?.cancel()
        addTask = nil
        return previous
    }

    private static func beginAddBrowserLogin(adapter: any VendorAdapter) {
        let previous = cancelRunning()
        addTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await runAdd(adapter: adapter)
        }
    }

    private static func runAdd(adapter: any VendorAdapter) async {
        IslandDialogController.shared.showProgress(
            title: "Sign in",
            message: adapter.id == "agy"
                ? "A Terminal window opens for Antigravity. Sign in there, then close it. This window waits up to 3 minutes."
                : String(localized: "Complete \(adapter.displayName) login in the browser or terminal. This window waits up to 3 minutes."),
            vendorID: adapter.id,
            onCancel: {
                addTask?.cancel()
                addTask = nil
            }
        )

        do {
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
                    message: String(localized: "You can add up to \(AccountStore.maxAccounts) accounts.")
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
                message: String(localized: "No adapter for vendor “\(account.vendorID)”.")
            )
            return
        }

        let message: String
        switch account.vendorID {
        case "claude":
            message = "Extending this Claude session. Browser sign-in only if the refresh token is dead."
        case "agy":
            message = "Extending this Antigravity session. A Terminal sign-in opens only if the stored session no longer works."
        default:
            message = String(localized: "Complete a fresh \(adapter.displayName) sign-in in the browser (up to 3 minutes). The current sign-in is kept until the new one succeeds.")
        }
        let previous = cancelRunning()
        addTask = Task {
            // Let a cancelled flow finish its cleanup before this one shows or stashes.
            await previous?.value
            guard !Task.isCancelled else { return }
            IslandDialogController.shared.showProgress(
                title: "Reauthenticate",
                message: message,
                vendorID: adapter.id,
                onCancel: {
                    addTask?.cancel()
                    addTask = nil
                }
            )
            defer { IslandDialogController.shared.hideProgress() }
            // No poll while the adapter has the session files moved aside; a
            // poll there left a red "reauth" for 30m after Cancel.
            await UsageOrchestrator.shared.beginReauth(accountID: account.id)
            var replaced = false
            defer { UsageOrchestrator.shared.endReauth(accountID: account.id, succeeded: replaced) }
            if Task.isCancelled { return }
            do {
                let newRef = try await adapter.reauthenticate(account.credentialRef)
                // The folder holds the new session now, even if Cancel came late.
                replaced = true
                if Task.isCancelled { return }
                try AccountStore.shared.markAuthenticated(id: account.id, credentialRef: newRef)
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
                title: String(localized: "Remove \(label)?"),
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
        case "agy":
            AgyAdapter.clearManagedCredentials(home: dir)
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
