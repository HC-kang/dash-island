import Foundation

/// Local Claude Code session activity for burn needle when `/api/oauth/usage`
/// only reports whole-percent utilization (flat for long stretches of real use).
///
/// Prefers **managed account** project trees under `CLAUDE_CONFIG_DIR` when the
/// island account owns that folder; falls back to host-wide `~/.claude/projects`
/// only for the account that matches the host login (`~/.claude.json`).
///
/// Does **not** touch Keychain or network. Reads files, so call it off the
/// main actor; pass one long-lived `LogCache` so each scan reads only new bytes.
enum ClaudeActivity {
    /// Lookback for "are you burning right now".
    static let defaultWindow: TimeInterval = 3 * 60

    /// Weighted tokens in the last `window` seconds + a crude burn ratio.
    ///
    /// Weight = input + output + cache_creation (not full cache_read — those
    /// dominate the log but are not 1:1 with rate-limit utilization).
    ///
    /// Ratio mapping (window-even 5h cruise is ~2% of limit per 5 min):
    /// ~25k weighted tokens / 3 min ≈ cruise (1.0); scales up to 3.
    static func liveBurnRatio(
        window: TimeInterval = defaultWindow,
        now: Date = Date(),
        configDir: URL? = nil,
        cache: LogCache = LogCache()
    ) -> Double {
        let tokens = recentWeightedTokens(window: window, now: now, configDir: configDir, cache: cache)
        guard tokens > 0 else { return 0 }
        // Tuned so a normal assistant turn with a few k new tokens moves the needle,
        // while a heavy burst pegs toward redline.
        let cruiseTokens = 25_000.0 * (window / 180.0)
        let ratio = Double(tokens) / cruiseTokens
        return min(3, max(0, ratio))
    }

    /// Whether the last signal used managed-folder logs (vs host-wide fallback).
    static func usedScopedLogs(configDir: URL?, window: TimeInterval = defaultWindow, now: Date = Date()) -> Bool {
        guard let configDir else { return false }
        return recentWeightedTokens(window: window, now: now, roots: projectRoots(for: configDir), cache: LogCache()) > 0
    }

    static func recentWeightedTokens(
        window: TimeInterval = defaultWindow,
        now: Date = Date(),
        configDir: URL? = nil,
        hostHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        cache: LogCache = LogCache()
    ) -> Int {
        if let configDir {
            let scoped = recentWeightedTokens(
                window: window,
                now: now,
                roots: projectRoots(for: configDir),
                cache: cache
            )
            if scoped > 0 { return scoped }
            // Host logs belong to the host login only — never lift every account's needle.
            guard let id = AccountUsageReader.identity(provider: "claude", home: configDir),
                  id == AccountUsageReader.identity(provider: "claude", home: hostHome)
            else { return 0 }
        }
        // Host-wide fallback (user's normal `claude` without CLAUDE_CONFIG_DIR).
        return recentWeightedTokens(window: window, now: now, roots: hostProjectRoots(home: hostHome), cache: cache)
    }

    /// Per-file read position plus the recent events already parsed from it.
    /// An unchanged file costs one `stat`; a grown file costs only its new bytes.
    final class LogCache: @unchecked Sendable {
        /// Oldest event kept. A caller's `window` must not exceed this.
        // ponytail: fixed retention; only `defaultWindow` (3m) is used today.
        static let retention: TimeInterval = 15 * 60
        /// First read of a file (or a jump past this many new bytes) reads the tail only.
        static let maxTailBytes: UInt64 = 1_500_000

        private struct Entry {
            var inode: UInt64
            var offset: UInt64 = 0
            var events: [(at: Date, weight: Int)] = []
            var lastSeen: Date = .distantPast
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var readCount = 0

        init() {}

        /// Total bytes read from disk so far. For tests.
        var bytesRead: Int {
            lock.lock(); defer { lock.unlock() }
            return readCount
        }

        func forget(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            entries[url.path] = nil
        }

        /// Drop files not seen since `date` (deleted or moved while warm).
        func evict(unseenSince date: Date) {
            lock.lock(); defer { lock.unlock() }
            entries = entries.filter { $0.value.lastSeen >= date }
        }

        func weightedTokens(in url: URL, since cutoff: Date, now: Date) -> Int {
            var st = stat()
            guard stat(url.path, &st) == 0 else { return 0 }
            let inode = UInt64(st.st_ino)
            let size = UInt64(max(0, st.st_size))

            lock.lock(); defer { lock.unlock() }
            var entry = entries[url.path] ?? Entry(inode: inode)
            // Replaced (new inode) or truncated: the old offset means nothing.
            if entry.inode != inode || size < entry.offset {
                entry = Entry(inode: inode)
            }
            if size > entry.offset {
                var from = entry.offset
                var midLine = false
                if size - from > Self.maxTailBytes {
                    from = size - Self.maxTailBytes
                    midLine = true
                }
                if let data = Self.read(url: url, from: from) {
                    readCount += data.count
                    let parsed = ClaudeActivity.parseEvents(data, dropFirstLine: midLine)
                    entry.events += parsed.events
                    entry.offset = from + UInt64(parsed.consumed)
                }
            }
            let keepFrom = now.addingTimeInterval(-Self.retention)
            entry.events.removeAll { $0.at < keepFrom }
            entry.lastSeen = now
            entries[url.path] = entry
            return entry.events.reduce(0) { $1.at >= cutoff ? $0 + $1.weight : $0 }
        }

        private static func read(url: URL, from offset: UInt64) -> Data? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            return try? handle.readToEnd()
        }
    }

    // MARK: - Internals

    private static func recentWeightedTokens(
        window: TimeInterval,
        now: Date,
        roots: [URL],
        cache: LogCache
    ) -> Int {
        let cutoff = now.addingTimeInterval(-window)
        var total = 0
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let item = enumerator.nextObject() as? URL {
                guard item.pathExtension == "jsonl" else { continue }
                let vals = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard vals?.isRegularFile == true else { continue }
                // Skip cold files (no writes in lookback + 1h slack).
                if let m = vals?.contentModificationDate, m < cutoff.addingTimeInterval(-3600) {
                    cache.forget(item)
                    continue
                }
                total += cache.weightedTokens(in: item, since: cutoff, now: now)
            }
        }
        return total
    }

    /// Managed `CLAUDE_CONFIG_DIR` layouts Claude Code may write under.
    static func projectRoots(for configDir: URL) -> [URL] {
        [
            configDir.appendingPathComponent("projects", isDirectory: true),
            configDir.appendingPathComponent(".claude/projects", isDirectory: true),
            configDir.appendingPathComponent("session-env", isDirectory: true),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func hostProjectRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        return [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let assistantMarker = Data(#""assistant""#.utf8)
    private static let usageMarker = Data(#""usage""#.utf8)

    /// Assistant usage events in `data`, and how many bytes were whole lines.
    /// A last line without its newline stays unconsumed unless it already parses,
    /// so a half-written line is read again on the next scan and counted once.
    private static func parseEvents(
        _ data: Data,
        dropFirstLine: Bool
    ) -> (events: [(at: Date, weight: Int)], consumed: Int) {
        var events: [(at: Date, weight: Int)] = []
        var start = data.startIndex
        var consumed = 0
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        // If we jumped into the middle of a file, drop the partial first line.
        if dropFirstLine, let firstNL = data.firstIndex(of: UInt8(ascii: "\n")) {
            start = data.index(after: firstNL)
            consumed = start - data.startIndex
        }

        while start < data.endIndex {
            let slice: Data
            let complete: Bool
            if let nl = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
                slice = data[start..<nl]
                start = data.index(after: nl)
                complete = true
            } else {
                slice = data[start...]
                start = data.endIndex
                complete = false
            }
            // Cheap byte checks first; most lines are not assistant usage.
            let candidate = slice.range(of: assistantMarker) != nil && slice.range(of: usageMarker) != nil
            let obj = candidate || !complete
                ? (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
                : nil
            // Half-written last line: leave it for the next scan.
            if !complete, obj == nil { break }
            consumed = start - data.startIndex
            guard candidate,
                  let obj,
                  obj["type"] as? String == "assistant",
                  let ts = parseTimestamp(obj["timestamp"], isoFrac: isoFrac, iso: iso),
                  let usage = assistantUsage(obj)
            else { continue }
            events.append((at: ts, weight: weight(usage)))
        }
        return (events, consumed)
    }

    private static func assistantUsage(_ obj: [String: Any]) -> [String: Any]? {
        if let message = obj["message"] as? [String: Any] {
            if let usage = message["usage"] as? [String: Any] { return usage }
            if let inner = message["message"] as? [String: Any],
               let usage = inner["usage"] as? [String: Any]
            {
                return usage
            }
        }
        return obj["usage"] as? [String: Any]
    }

    private static func weight(_ usage: [String: Any]) -> Int {
        let input = intVal(usage["input_tokens"])
        let output = intVal(usage["output_tokens"])
        let create = intVal(usage["cache_creation_input_tokens"])
        // cache_read is large and often discounted — count at 5%.
        let read = intVal(usage["cache_read_input_tokens"])
        return input + output + create + read / 20
    }

    private static func intVal(_ v: Any?) -> Int {
        if let i = v as? Int { return max(0, i) }
        if let i = v as? Int64 { return max(0, Int(i)) }
        if let d = v as? Double { return max(0, Int(d)) }
        return 0
    }

    private static func parseTimestamp(
        _ value: Any?,
        isoFrac: ISO8601DateFormatter,
        iso: ISO8601DateFormatter
    ) -> Date? {
        if let s = value as? String {
            if let d = isoFrac.date(from: s) { return d }
            if let d = iso.date(from: s) { return d }
            let zulu = s.replacingOccurrences(of: "+00:00", with: "Z")
            if let d = isoFrac.date(from: zulu) { return d }
            return iso.date(from: zulu)
        }
        if let n = value as? Double {
            let sec = n > 1e12 ? n / 1000 : n
            return Date(timeIntervalSince1970: sec)
        }
        if let n = value as? Int {
            let sec = n > 1_000_000_000_000 ? Double(n) / 1000 : Double(n)
            return Date(timeIntervalSince1970: sec)
        }
        return nil
    }
}
