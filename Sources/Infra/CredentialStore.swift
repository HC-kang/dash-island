import Foundation

/// On-disk credential layout under Application Support.
///
/// Lives **outside** the app bundle so rebuild / re-sign / re-`open` never wipe it.
///
/// ```
/// ~/Library/Application Support/DashIsland/
///   accounts.json                 ← account metadata (id, vendor, label, order)
///   accounts.corrupt.*.json       ← auto-backup if decode fails
///   accounts/<uuid>/              ← CredentialRef (adapter-owned files)
///     Claude: .credentials.json
///     Codex:  auth.json
///     Grok:   auth.json
/// ```
enum CredentialStoreError: Error, Equatable {
    case invalidRef
}

enum CredentialStore {
    static let appFolderName = "DashIsland"

    /// `~/Library/Application Support/DashIsland/`
    static var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    /// `~/Library/Application Support/DashIsland/accounts/`
    static var rootURL: URL {
        appSupportURL.appendingPathComponent("accounts", isDirectory: true)
    }

    /// `~/Library/Application Support/DashIsland/accounts.json`
    static var accountsFileURL: URL {
        appSupportURL.appendingPathComponent("accounts.json", isDirectory: false)
    }

    /// Directory for a single account credential ref: `accounts/<ref>/`.
    static func directoryURL(for ref: CredentialRef, root: URL = rootURL) -> URL {
        root.appendingPathComponent(ref, isDirectory: true)
    }

    /// A ref is exactly one folder name under `accounts/`. `""`, `.` and `..`
    /// resolve to the root or its parent, so removing one would delete every account.
    static func isValidRef(_ ref: CredentialRef) -> Bool {
        !ref.isEmpty && ref != "." && ref != ".." && !ref.contains("/") && !ref.contains("\0")
    }

    private static func checkedDirectoryURL(for ref: CredentialRef, root: URL) throws -> URL {
        let url = directoryURL(for: ref, root: root)
        guard isValidRef(ref),
              url.standardizedFileURL.deletingLastPathComponent().path
                == root.standardizedFileURL.path
        else {
            Log.accounts.error("credentialRef rejected length=\(ref.count)")
            throw CredentialStoreError.invalidRef
        }
        return url
    }

    /// App-owned last-good usage cache (error-free rings) for one managed account.
    /// File-only — never Keychain. Survives app restart under soft quiet / 429.
    static let lastGoodFileName = ".dash-island-usage.json"

    static func lastGoodUsageURL(inDirectory dir: URL) -> URL {
        dir.appendingPathComponent(lastGoodFileName, isDirectory: false)
    }

    static func lastGoodUsageURL(for ref: CredentialRef) -> URL {
        lastGoodUsageURL(inDirectory: directoryURL(for: ref))
    }

    /// Drop last-good rings for a managed folder (identity change / wipe).
    static func removeLastGoodUsage(inDirectory dir: URL) {
        let url = lastGoodUsageURL(inDirectory: dir)
        try? FileManager.default.removeItem(at: url)
    }

    /// Create `accounts/<ref>/` (and parents), owner-only. Returns the directory URL.
    @discardableResult
    static func createDirectory(for ref: CredentialRef, root: URL = rootURL) throws -> URL {
        let url = try checkedDirectoryURL(for: ref, root: root)
        let fm = FileManager.default
        try fm.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Folders made by older builds are 0755.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Remove `accounts/<ref>/` if it exists. Refuses anything but one child of `root`.
    static func removeDirectory(for ref: CredentialRef, root: URL = rootURL) throws {
        let url = try checkedDirectoryURL(for: ref, root: root)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Write a credential file: atomic, owner-only (0600), then read back.
    /// A rotated refresh token that silently fails to land is gone for good.
    /// One-time migration: folders created before 0700 was enforced stay 0755
    /// until a reauth. Tighten the root and every account folder; returns how many changed.
    @discardableResult
    static func tightenPermissions(root: URL = rootURL) -> Int {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let dirs = [root] + children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var changed = 0
        for dir in dirs {
            let mode = (try? fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
            guard let mode, mode != 0o700 else { continue }
            if (try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)) != nil { changed += 1 }
        }
        return changed
    }

    static func writeSecret(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard (try? Data(contentsOf: url)) == data else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Reauth keeps the live session until the new login is accepted.
    ///
    /// `stash` moves each session file to `<name>.prior` so the CLI starts
    /// signed out. `restore` drops whatever the failed login wrote and moves the
    /// old files back; `discard` deletes the copies after success. A copy left by
    /// a crashed reauth (no live file) is adopted, so the next attempt restores it.
    struct PriorFiles {
        let paths: [URL]
        let moved: [URL]

        static func priorURL(for url: URL) -> URL {
            url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".prior")
        }

        static func stash(_ paths: [URL]) -> PriorFiles {
            let fm = FileManager.default
            var moved: [URL] = []
            for path in paths {
                let prior = priorURL(for: path)
                if fm.fileExists(atPath: path.path) {
                    try? fm.removeItem(at: prior)
                    if (try? fm.moveItem(at: path, to: prior)) != nil { moved.append(path) }
                } else if fm.fileExists(atPath: prior.path) {
                    moved.append(path)
                }
            }
            return PriorFiles(paths: paths, moved: moved)
        }

        func restore() {
            let fm = FileManager.default
            for path in paths where fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
            for path in moved {
                try? fm.moveItem(at: Self.priorURL(for: path), to: path)
            }
        }

        func discard() {
            for path in moved {
                try? FileManager.default.removeItem(at: Self.priorURL(for: path))
            }
        }
    }

    /// Launch-time cleanup after a crash mid-reauth: a lone `x.prior` goes back to
    /// `x`; a `.prior` next to a live file is stale (the new login landed) and is
    /// removed. Returns how many files changed.
    @discardableResult
    static func recoverPriorFiles(root: URL = rootURL) -> Int {
        let fm = FileManager.default
        var changed = 0
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in files where name.hasSuffix(".prior") {
                let prior = dir.appendingPathComponent(name)
                let live = dir.appendingPathComponent(String(name.dropLast(".prior".count)))
                if fm.fileExists(atPath: live.path) {
                    if (try? fm.removeItem(at: prior)) != nil { changed += 1 }
                } else if (try? fm.moveItem(at: prior, to: live)) != nil {
                    changed += 1
                }
            }
        }
        return changed
    }

    /// Subdirectories under `accounts/` (each name is a potential `CredentialRef`).
    static func listCredentialRefs() -> [CredentialRef] {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return kids.compactMap { url -> String? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return url.lastPathComponent
        }
    }

    /// Best-effort vendor detection from files already on disk (for recovery).
    static func detectVendor(in dir: URL) -> VendorID? {
        let fm = FileManager.default
        let claudeCreds = dir.appendingPathComponent(".credentials.json", isDirectory: false)
        if fm.fileExists(atPath: claudeCreds.path),
           let data = try? Data(contentsOf: claudeCreds),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["claudeAiOauth"] != nil
        {
            return "claude"
        }

        let auth = dir.appendingPathComponent("auth.json", isDirectory: false)
        let nestedCodex = dir.appendingPathComponent(".codex/auth.json", isDirectory: false)
        for path in [auth, nestedCodex] {
            guard fm.fileExists(atPath: path.path),
                  let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Codex: tokens.access_token
            if let tokens = obj["tokens"] as? [String: Any],
               let access = tokens["access_token"] as? String,
               !access.isEmpty
            {
                return "codex"
            }
            // Grok: issuer map with `key`, or top-level access-ish fields from Orca layout
            if obj["https://auth.x.ai"] != nil || obj["https://auth.x.ai/"] != nil {
                return "grok"
            }
            if let key = obj["key"] as? String, !key.isEmpty {
                return "grok"
            }
        }

        let nestedGrok = dir.appendingPathComponent(".grok/auth.json", isDirectory: false)
        if fm.fileExists(atPath: nestedGrok.path) {
            return "grok"
        }

        let geminiCreds = [
            dir.appendingPathComponent(".gemini/oauth_creds.json", isDirectory: false),
            dir.appendingPathComponent("oauth_creds.json", isDirectory: false),
        ]
        for path in geminiCreds {
            guard fm.fileExists(atPath: path.path),
                  let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String,
                  !access.isEmpty
            else { continue }
            return "agy"
        }

        return nil
    }
}
