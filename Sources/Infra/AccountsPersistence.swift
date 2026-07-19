import Foundation

/// JSON list IO for `[Account]` at a file URL (typically `accounts.json`).
struct AccountsPersistence: Sendable {
    var fileURL: URL

    static var live: AccountsPersistence {
        AccountsPersistence(fileURL: CredentialStore.accountsFileURL)
    }

    /// Load accounts; missing file → empty list.
    func load() throws -> [Account] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Account].self, from: data)
    }

    /// Atomically write the full account list.
    func save(_ accounts: [Account]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        try data.write(to: fileURL, options: .atomic)
    }
}
