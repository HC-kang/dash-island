import Foundation

/// Local Claude Code session activity for burn needle when `/api/oauth/usage`
/// only reports whole-percent utilization (flat for long stretches of real use).
///
/// Reads `~/.claude/projects/**/*.jsonl` (and `~/.config/claude/projects`).
/// Does **not** touch Keychain or network. Multi-account island accounts share
/// this host-wide signal — good enough when the user is actively running Claude Code.
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
        now: Date = Date()
    ) -> Double {
        let tokens = recentWeightedTokens(window: window, now: now)
        guard tokens > 0 else { return 0 }
        // Tuned so a normal assistant turn with a few k new tokens moves the needle,
        // while a heavy burst pegs toward redline.
        let cruiseTokens = 25_000.0 * (window / 180.0)
        let ratio = Double(tokens) / cruiseTokens
        return min(3, max(0, ratio))
    }

    static func recentWeightedTokens(
        window: TimeInterval = defaultWindow,
        now: Date = Date()
    ) -> Int {
        let cutoff = now.addingTimeInterval(-window)
        var total = 0
        let fm = FileManager.default
        for root in projectRoots() {
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
                    continue
                }
                total += weightedTokens(in: item, since: cutoff)
            }
        }
        return total
    }

    // MARK: - Internals

    private static func projectRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func weightedTokens(in url: URL, since cutoff: Date) -> Int {
        guard let data = tailData(url: url, maxBytes: 1_500_000), !data.isEmpty else { return 0 }
        var sum = 0
        var start = data.startIndex
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        // If we jumped into the middle of a file, drop the partial first line.
        if let firstNL = data.firstIndex(of: UInt8(ascii: "\n")),
           (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > data.count
        {
            start = data.index(after: firstNL)
        }

        while start < data.endIndex {
            let slice: Data
            if let nl = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
                slice = data[start..<nl]
                start = data.index(after: nl)
            } else {
                slice = data[start...]
                start = data.endIndex
            }
            guard !slice.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any],
                  obj["type"] as? String == "assistant"
            else { continue }

            guard let ts = parseTimestamp(obj["timestamp"], isoFrac: isoFrac, iso: iso),
                  ts >= cutoff
            else { continue }

            guard let usage = assistantUsage(obj) else { continue }
            sum += weight(usage)
        }
        return sum
    }

    private static func tailData(url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        if size <= 0 { return nil }
        if size > maxBytes {
            try? handle.seek(toOffset: UInt64(size - maxBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        return try? handle.readToEnd()
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
