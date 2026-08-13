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
    static func directoryURL(for ref: CredentialRef) -> URL {
        rootURL.appendingPathComponent(ref, isDirectory: true)
    }

    /// App-owned last-good usage cache (error-free rings) for one managed account.
    /// File-only — never Keychain. Survives app restart under soft quiet / 429.
    static func lastGoodUsageURL(for ref: CredentialRef) -> URL {
        directoryURL(for: ref).appendingPathComponent(".dash-island-usage.json")
    }

    /// Create `accounts/<ref>/` (and parents). Returns the directory URL.
    @discardableResult
    static func createDirectory(for ref: CredentialRef) throws -> URL {
        let url = directoryURL(for: ref)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Remove `accounts/<ref>/` if it exists.
    static func removeDirectory(for ref: CredentialRef) throws {
        let url = directoryURL(for: ref)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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

        return nil
    }
}
