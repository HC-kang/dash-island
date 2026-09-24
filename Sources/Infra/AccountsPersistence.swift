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
    /// A bad row is skipped (file backed up) so one damaged entry cannot drop every label.
    /// Corrupt file or no readable row → leave it in place (backed up) and throw so callers can decide.
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
            let rows = try decoder.decode([LossyRow].self, from: data)
            let accounts = rows.compactMap(\.account)
            let skipped = rows.count - accounts.count
            if skipped > 0 {
                guard !accounts.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try? backupCorruptFile(data: data)
                Log.accounts.warn("load skipped=\(skipped) kept=\(accounts.count)")
            }
            return accounts
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
                Log.accounts.warn("save refused reason=empty-over-existing path=\(fileURL.path)")
                return
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        try data.write(to: fileURL, options: .atomic)
    }

    /// One array element; a row that does not decode becomes nil instead of failing the list.
    private struct LossyRow: Decodable {
        let account: Account?
        init(from decoder: Decoder) throws { account = try? Account(from: decoder) }
    }

    private func backupCorruptFile(data: Data) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("accounts.corrupt.\(stamp).json", isDirectory: false)
        try data.write(to: backup, options: .atomic)
        Log.accounts.error("corrupt backup=\(backup.path)")
    }
}
