import Foundation

enum ClaudeActivitySuite {
    static func run() -> Int {
        print("ClaudeActivity")
        var failures = 0
        let fm = FileManager.default

        /// Managed config dir with one project log. No host home match needed:
        /// scoped logs are read first.
        func makeDir() throws -> (dir: URL, log: URL) {
            let dir = fm.temporaryDirectory.appendingPathComponent("di-activity-cache-\(UUID().uuidString)")
            let projects = dir.appendingPathComponent("projects/p")
            try fm.createDirectory(at: projects, withIntermediateDirectories: true)
            return (dir, projects.appendingPathComponent("s.jsonl"))
        }
        func line(_ at: Date, output: Int) -> String {
            let stamp = ISO8601DateFormatter().string(from: at)
            return #"{"type":"assistant","timestamp":"\#(stamp)","message":{"usage":{"output_tokens":\#(output)}}}"# + "\n"
        }
        func append(_ text: String, to url: URL) throws {
            if !fm.fileExists(atPath: url.path) {
                try Data(text.utf8).write(to: url)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
        let host = fm.temporaryDirectory.appendingPathComponent("di-activity-nohost-\(UUID().uuidString)")

        failures += check("unchanged log is not read again; appended bytes only") {
            let (dir, log) = try makeDir()
            defer { try? fm.removeItem(at: dir) }
            let now = Date()
            let first = line(now.addingTimeInterval(-30), output: 1000)
            try append(first, to: log)
            let cache = ClaudeActivity.LogCache()

            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 1000)
            try assertEqual(cache.bytesRead, first.utf8.count)

            // Nothing changed: same answer, no bytes read.
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 1000)
            try assertEqual(cache.bytesRead, first.utf8.count)

            let second = line(now.addingTimeInterval(-10), output: 500)
            try append(second, to: log)
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 1500)
            try assertEqual(cache.bytesRead, first.utf8.count + second.utf8.count)
        }

        failures += check("half-written line waits for its newline and counts once") {
            let (dir, log) = try makeDir()
            defer { try? fm.removeItem(at: dir) }
            let now = Date()
            try append(line(now.addingTimeInterval(-30), output: 1000), to: log)
            let cache = ClaudeActivity.LogCache()
            _ = ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache)

            let next = line(now.addingTimeInterval(-5), output: 200)
            let cut = next.index(next.startIndex, offsetBy: 40)
            try append(String(next[..<cut]), to: log)
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 1000)
            try append(String(next[cut...]), to: log)
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 1200)
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 1200)
        }

        failures += check("replaced or truncated log starts over") {
            let (dir, log) = try makeDir()
            defer { try? fm.removeItem(at: dir) }
            let now = Date()
            try append(line(now.addingTimeInterval(-30), output: 1000) + line(now.addingTimeInterval(-20), output: 1000), to: log)
            let cache = ClaudeActivity.LogCache()
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 2000)

            // Atomic replace: new inode, shorter file.
            try Data(line(now.addingTimeInterval(-10), output: 300).utf8).write(to: log, options: .atomic)
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 300)
        }

        failures += check("cached events still age out of the window") {
            let (dir, log) = try makeDir()
            defer { try? fm.removeItem(at: dir) }
            let now = Date()
            try append(line(now.addingTimeInterval(-30), output: 1000), to: log)
            let cache = ClaudeActivity.LogCache()
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: cache), 1000)
            let later = now.addingTimeInterval(ClaudeActivity.defaultWindow)
            try assertEqual(ClaudeActivity.recentWeightedTokens(now: later, configDir: dir, hostHome: host, cache: cache), 0)
        }

        failures += check("lines without assistant usage are skipped") {
            let (dir, log) = try makeDir()
            defer { try? fm.removeItem(at: dir) }
            let now = Date()
            let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30))
            try append(#"{"type":"user","timestamp":"\#(stamp)","message":{"content":"assistant usage"}}"# + "\n", to: log)
            try append("not json\n", to: log)
            try append(line(now.addingTimeInterval(-20), output: 700), to: log)
            try assertEqual(
                ClaudeActivity.recentWeightedTokens(now: now, configDir: dir, hostHome: host, cache: ClaudeActivity.LogCache()),
                700
            )
        }

        return failures
    }
}
