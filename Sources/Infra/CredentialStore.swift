import Foundation

/// On-disk credential layout under Application Support.
///
/// ```
/// ~/Library/Application Support/DashIsland/
///   accounts.json
///   accounts/<uuid>/          ← CredentialRef (adapter-owned files inside)
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
}
