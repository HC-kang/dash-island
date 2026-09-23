import Foundation
import CryptoKit

enum LocalUsageReader {
    struct Result {
        var events: [LocalUsageEvent]
        var incomplete: Bool
    }

    static func parse(_ file: URL, provider: String, now: Date = Date()) throws -> Result {
        var events: [String: LocalUsageEvent] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return iso.date(from: text) ?? plain.date(from: text)
        }
        var model = "Unknown model"
        var session = file.lastPathComponent
        var sessionStart: Date?
        var isFork = false
        var epoch = "initial"
        var previousTotal: Int64 = 0
        var incomplete = false
        try UsageLogLines.streamLines(at: file) { line in
            guard line.range(of: Data((provider == "claude" ? "\"usage\"" : "\"payload\"").utf8)) != nil else { return }
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                incomplete = true
                return
            }
            let type = row["type"] as? String
            let payload = row["payload"] as? [String: Any] ?? [:]
            if provider == "codex", type == "session_meta" {
                session = payload["id"] as? String ?? payload["session_id"] as? String ?? session
                sessionStart = date(payload["timestamp"])
                isFork = payload["forked_from_id"] != nil || payload["parent_thread_id"] != nil
                return
            }
            if provider == "codex", type == "turn_context" {
                model = payload["model"] as? String ?? "Unknown model"
                return
            }
            let usage: [String: Any]
            let key: String
            let eventModel: String
            guard let timestamp = date(row["timestamp"]), timestamp <= now else { return }
            if provider == "claude" {
                guard type == "assistant", let message = row["message"] as? [String: Any],
                      let values = message["usage"] as? [String: Any] else { return }
                eventModel = message["model"] as? String ?? "Unknown model"
                guard !eventModel.contains("synthetic") else { return }
                usage = values
                if let id = message["id"] as? String, !id.isEmpty {
                    key = "claude:\(id):\(row["requestId"] as? String ?? "")"
                } else if let id = row["uuid"] as? String {
                    key = "claude:\(id)"
                } else {
                    incomplete = true
                    return // No stable identity: do not invent persistent money totals.
                }
            } else {
                guard type == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let values = info["last_token_usage"] as? [String: Any] else { return }
                // Forks can carry the parent's transcript. Only retain the new session's calls.
                if isFork, let sessionStart, timestamp < sessionStart { return }
                usage = values
                eventModel = model
                if let cumulative = info["total_token_usage"] as? [String: Any],
                   let total = integer(cumulative["total_tokens"]), total > 0,
                   let encoded = try? JSONSerialization.data(withJSONObject: cumulative, options: [.sortedKeys]) {
                    if total < previousTotal { epoch = "\(timestamp.timeIntervalSince1970)" }
                    previousTotal = total
                    key = "codex:\(session):\(epoch):\(digest(encoded))"
                } else {
                    // Older logs: per-event timestamp + session, never a guessed model.
                    key = "codex:\(session):\(timestamp.timeIntervalSince1970)"
                }
            }
            guard let tokens = tokens(usage, provider: provider) else { incomplete = true; return }
            guard tokens.total > 0 else { return }
            let event = LocalUsageEvent(id: key, date: timestamp, model: eventModel, tokens: tokens)
            if let old = events[key] {
                // A streaming repeat replaces a real row only when it is more complete.
                if event.model == old.model && tokens.contains(old.tokens) {
                    var replacement = event
                    replacement.date = min(old.date, timestamp)
                    events[key] = replacement
                }
            } else { events[key] = event }
        }
        return Result(events: Array(events.values), incomplete: incomplete)
    }

    static func tokens(_ usage: [String: Any], provider: String) -> UsageTokens? {
        func value(_ key: String) -> Int64? { usage[key] == nil ? 0 : integer(usage[key]) }
        guard let input = value("input_tokens"), let output = value("output_tokens"),
              let read = value(provider == "codex" ? "cached_input_tokens" : "cache_read_input_tokens"),
              let write = value(provider == "codex" ? "cache_write_input_tokens" : "cache_creation_input_tokens") else { return nil }
        var tokens = UsageTokens(input: input, output: output, cacheWrite: write, cacheRead: read)
        if provider == "codex" {
            // Cached reads belong to input. Newer schemas may report writes separately;
            // use the recorded total to disambiguate instead of charging them twice.
            var includedWrite = write
            if write > 0 {
                guard let total = integer(usage["total_tokens"]) else { return nil }
                if total == input + output + write { includedWrite = 0 }
                else if total != input + output { return nil }
            }
            tokens.input = input - read - includedWrite
        }
        return tokens.valid ? tokens : nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d >= 0, d <= 1_000_000_000_000, d.rounded() == d else { return nil }
        return number.int64Value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One writer for the metadata archive. Credentials and conversation content never enter it.
actor LocalUsageArchive {
    static let shared = LocalUsageArchive(directory: CredentialStore.appSupportURL.appendingPathComponent("usage-history"))
    private let directory: URL
    private var loaded: [String: Archive] = [:]
    private var unreadable = Set<String>()

    struct Stamp: Codable, Equatable {
        var modified: Date
        var size: Int
        var walModified: Date? = nil
        var walSize: Int? = nil
    }
    struct Archive: Codable {
        var version = 1
        var events: [String: LocalUsageEvent] = [:]
        var files: [String: Stamp] = [:]
        var incompleteFiles: Set<String> = []

        init(events: [String: LocalUsageEvent] = [:]) { self.events = events }

        // Missing keys take their defaults, so adding a field never makes saved history unreadable.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            events = try c.decodeIfPresent([String: LocalUsageEvent].self, forKey: .events) ?? [:]
            files = try c.decodeIfPresent([String: Stamp].self, forKey: .files) ?? [:]
            incompleteFiles = try c.decodeIfPresent(Set<String>.self, forKey: .incompleteFiles) ?? []
        }
    }
    struct Snapshot: Sendable {
        var events: [LocalUsageEvent]
        var notice: String?
    }
    init(directory: URL) { self.directory = directory }

    func cached(provider: String, scope: String? = nil) -> Snapshot {
        let key = scope ?? provider
        if loaded[key] == nil {
            let file = directory.appendingPathComponent("\(key).json")
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    let value = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                    guard value.version == 1, value.events.values.allSatisfy({ $0.tokens.valid && $0.date.timeIntervalSince1970.isFinite }) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    loaded[key] = value
                } catch { unreadable.insert(key) }
            }
            if loaded[key] == nil { loaded[key] = Archive() }
        }
        return Snapshot(events: Array(loaded[key]!.events.values), notice: unreadable.contains(key)
            ? "Saved history could not be read. Original file preserved."
            : (loaded[key]!.incompleteFiles.isEmpty ? nil : "Some local records could not be included."))
    }

    func refresh(provider: String, roots: [URL], scope: String? = nil, now: Date = Date()) -> Snapshot {
        let key = scope ?? provider
        _ = cached(provider: provider, scope: scope)
        var archive = loaded[key]!
        let fm = FileManager.default
        var readError = false
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        for root in Set(roots.map { $0.standardizedFileURL }) where fm.fileExists(atPath: root.path) {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in readError = true; return true }) else { readError = true; continue }
            for case let file as URL in walker where Self.isUsageFile(file, provider: provider) {
                do {
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let modified = values.contentModificationDate,
                          let size = values.fileSize else { continue }
                    let wal = provider == "agy" ? try? URL(fileURLWithPath: file.path + "-wal")
                        .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) : nil
                    guard max(modified, wal?.contentModificationDate ?? .distantPast) >= cutoff else { continue }
                    let stamp = Stamp(modified: modified, size: size, walModified: wal?.contentModificationDate, walSize: wal?.fileSize)
                    guard archive.files[file.path] != stamp else { continue }
                    let parsed: LocalUsageReader.Result
                    switch provider {
                    case "grok": parsed = try GrokUsageReader.read(file)
                    case "agy": parsed = try AntigravityUsageReader.read(file)
                    default: parsed = try LocalUsageReader.parse(file, provider: provider, now: now)
                    }
                    for event in parsed.events where event.date <= now && event.tokens.valid {
                        if let old = archive.events[event.id], old.model == event.model {
                            if event.tokens.contains(old.tokens) { archive.events[event.id] = event }
                        } else { archive.events[event.id] = event }
                    }
                    archive.files[file.path] = stamp
                    if parsed.incomplete { archive.incompleteFiles.insert(file.path) }
                    else { archive.incompleteFiles.remove(file.path) }
                } catch { readError = true }
            }
        }
        // ponytail: one atomic JSON archive per provider; switch to SQLite if retained metadata becomes large.
        var notice: String? = readError || !archive.incompleteFiles.isEmpty ? "Some local records could not be included." : nil
        if unreadable.contains(key) {
            notice = "Saved history could not be read. Original file preserved."
        } else {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("\(key).json")
                try JSONEncoder().encode(archive).write(to: file, options: [.atomic])
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { notice = "History could not be saved. Current readings are still shown." }
        }
        loaded[key] = archive
        return Snapshot(events: Array(archive.events.values), notice: notice)
    }

    private static func isUsageFile(_ file: URL, provider: String) -> Bool {
        switch provider {
        case "agy": return file.pathExtension == "db"
        case "grok": return file.lastPathComponent == "updates.jsonl"
        default: return file.pathExtension == "jsonl"
        }
    }
}
