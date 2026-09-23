import Foundation

enum LogSuite {
    static func run() -> Int {
        print("Log")
        var failures = 0

        failures += check("format: timestamp, letter, category, escaped newline") {
            let line = Log.format(.warn, "poll", "skip a=1\nb=2", at: Date(timeIntervalSince1970: 0))
            let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{4} W \[poll\] skip a=1⏎b=2$"#
            guard line.range(of: pattern, options: .regularExpression) != nil else {
                throw TestFailure(description: "bad line: \(line)")
            }
        }

        failures += check("level filter skips debug autoclosure at info") {
            let saved = Log.level
            defer { Log.level = saved }
            Log.level = .info
            var evaluated = false
            Log.poll.debug({ evaluated = true; return "x" }())
            try assertEqual(evaluated, false)
            Log.level = .debug
            Log.poll.debug({ evaluated = true; return "x" }())
            try assertEqual(evaluated, true)
        }

        failures += check("resolveLevel: env > defaults > info, unknown falls through") {
            let suite = "LogTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try assertEqual(Log.resolveLevel(env: [:], defaults: defaults), .info)
            defaults.set("warn", forKey: "DashIsland.logLevel")
            try assertEqual(Log.resolveLevel(env: [:], defaults: defaults), .warn)
            try assertEqual(Log.resolveLevel(env: ["DASHISLAND_LOG": "debug"], defaults: defaults), .debug)
            try assertEqual(Log.resolveLevel(env: ["DASHISLAND_LOG": "loud"], defaults: defaults), .warn)
        }

        failures += check("rotation keeps .1….3 and restarts .log") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("t.log")
            let file = LogFile(url: url, maxBytes: 100, keep: 3)!
            // 60-byte lines: a rotation after every 2nd line (after L1, L3, L5, L7, L9).
            for i in 0..<10 {
                file.append("L\(i)" + String(repeating: "x", count: 57))
            }
            func read(_ suffix: String) -> String? {
                try? String(contentsOf: URL(fileURLWithPath: url.path + suffix), encoding: .utf8)
            }
            try assertEqual(read(""), "")
            try assertEqual(read(".1")?.contains("L9"), true)
            try assertEqual(read(".3")?.contains("L4"), true)
            try assertEqual(read(".4"), nil)
        }

        failures += check("concurrent appends keep whole lines") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("c.log")
            let file = LogFile(url: url, maxBytes: 10_000_000, keep: 3)!
            DispatchQueue.concurrentPerform(iterations: 8) { t in
                for i in 0..<200 { file.append("t=\(t) i=\(i) end") }
            }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            try assertEqual(lines.count, 1600)
            try assertEqual(lines.allSatisfy { $0.hasPrefix("t=") && $0.hasSuffix(" end") }, true)
        }

        failures += check("startFile on unwritable path leaves sink off") {
            Log.startFile(at: URL(fileURLWithPath: "/dev/null/nope/x.log"))
            try assertEqual(Log.fileURL, nil)
            Log.app.error("still no crash")
        }

        failures += check("redact and UUID.short") {
            try assertEqual(Log.redact(nil), "nil")
            try assertEqual(Log.redact("abcdefghij"), "abcdef…")
            try assertEqual(Log.redact("abc"), "…")
            try assertEqual(Log.redact("abcdef"), "…")
            let id = UUID(uuidString: "9C11FBE9-0000-0000-0000-000000000000")!
            try assertEqual(id.short, "9C11FBE9")
        }

        return failures
    }

    // Same private helper pattern as the other suites (each suite owns its copy).
    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
