import Foundation
import CryptoKit
import SQLite3

/// Joins completed-call telemetry to provider identity, never to a current global login.
enum AccountUsageReader {
    static var directory: URL { CredentialStore.appSupportURL.appendingPathComponent("tracking") }

    static func identity(provider: String, account: String, organization: String = "") -> String? {
        guard !account.isEmpty, account.count <= 512, organization.count <= 512 else { return nil }
        let value = provider + "\0" + account.lowercased() + "\0" + organization.lowercased()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func identity(provider: String, home: URL) -> String? {
        if provider == "codex", let id = CodexAdapter.readCredentials(codexHome: home)?.accountID {
            return identity(provider: provider, account: id)
        }
        if provider == "claude",
           let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = root["oauthAccount"] as? [String: Any],
           let account = oauth["accountUuid"] as? String,
           let organization = oauth["organizationUuid"] as? String {
            return identity(provider: provider, account: account, organization: organization)
        }
        return nil
    }

    static func read(provider: String, identity: String?, directory: URL = directory,
                     now: Date = Date()) -> LocalUsageArchive.Snapshot {
        guard let identity else {
            return .init(events: [], notice: "Account identity unavailable. Reauthenticate this account to reconnect tracking.")
        }
        let result = readAccounts(provider: provider, directory: directory, now: now)
        return .init(events: result.accounts[identity] ?? [], notice: result.notice)
    }

    // Read all identities in one SQLite snapshot so account and total views agree.
    static func readAccounts(provider: String, directory: URL = directory,
                             now: Date = Date()) -> (accounts: [String: [LocalUsageEvent]], notice: String?) {
        let file = directory.appendingPathComponent("account-usage.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return (accounts: [:], notice: "Account tracking is not connected yet.")
        }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            return (accounts: [:], notice: "Account history could not be read. Try again shortly.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        let sql = """
        SELECT event_id,timestamp,model,input,output,cache_write,cache_read,dollars,identity
        FROM usage_events WHERE provider=? AND timestamp>=? AND timestamp<=?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return (accounts: [:], notice: "Account history format could not be read.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, provider, -1, transient)
        let start = Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: now))!
        sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
        var accounts: [String: [LocalUsageEvent]] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return (accounts: accounts, notice: nil) }
            guard status == SQLITE_ROW, let id = sqlite3_column_text(statement, 0), let model = sqlite3_column_text(statement, 2),
                  let identity = sqlite3_column_text(statement, 8) else {
                return (accounts: accounts, notice: "Some account records could not be read.")
            }
            let tokens = UsageTokens(input: sqlite3_column_int64(statement, 3), output: sqlite3_column_int64(statement, 4),
                                     cacheWrite: sqlite3_column_int64(statement, 5), cacheRead: sqlite3_column_int64(statement, 6))
            guard tokens.valid else { continue }
            accounts[String(cString: identity), default: []].append(LocalUsageEvent(id: String(cString: id), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                model: String(cString: model), tokens: tokens,
                reportedDollars: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 7)))
        }
    }
}
