import Foundation

/// JSON list IO for `[Account]` at a file URL (typically `accounts.json`).
///
/// Path (live): `~/Library/Application Support/DashIsland/accounts.json`
/// Survives app rebuilds / re-launches — never stored inside the `.app` bundle.
struct AccountsPersistence: Sendable {
    var fileURL: URL

    static var live: AccountsPersistence {
        AccountsPersistence(fileURL: CredentialStore.accountsFileURL)
    }

    /// Load accounts; missing file → empty list.
    /// Corrupt file → leave it in place (backed up) and throw so callers can decide.
    func load() throws -> [Account] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return []
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Account].self, from: data)
        } catch {
            // Never silently destroy a corrupt list — keep original + sidecar backup.
            try? backupCorruptFile(data: data)
            throw error
        }
    }

    /// Atomically write the full account list.
    /// Refuses to overwrite a non-empty on-disk file with an empty list unless
    /// `allowEmptyOverwrite` is true (explicit "remove last account").
    func save(_ accounts: [Account], allowEmptyOverwrite: Bool = false) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if accounts.isEmpty && !allowEmptyOverwrite {
            let existing = (try? Data(contentsOf: fileURL)) ?? Data()
            if !existing.isEmpty {
                // Safety: empty save would wipe registered accounts.
                NSLog(
                    "DashIsland: refused empty accounts save over existing file at %@",
                    fileURL.path
                )
                return
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        try data.write(to: fileURL, options: .atomic)
    }

    private func backupCorruptFile(data: Data) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("accounts.corrupt.\(stamp).json", isDirectory: false)
        try data.write(to: backup, options: .atomic)
        NSLog("DashIsland: backed up corrupt accounts.json → %@", backup.path)
    }
}
