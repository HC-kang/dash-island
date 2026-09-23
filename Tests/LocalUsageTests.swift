import Foundation
import SQLite3

enum LocalUsageSuite {
    static func run() async -> Int {
        var failures = 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return 1 }
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let logs = root.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("rollout-test.jsonl")
        let lines = """
        {"type":"session_meta","payload":{"id":"test-session"}}
        {"type":"turn_context","payload":{"model":"gpt-test"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":20,"output_tokens":10,"total_tokens":110}}}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"cache_write_input_tokens":20,"output_tokens":10,"total_tokens":110}}}}
        """
        failures += check("Codex repeated cumulative usage counts once, with disjoint cache categories") {
            try Data(lines.utf8).write(to: file)
            let result = try LocalUsageReader.parse(file, provider: "codex", now: now)
            try assertEqual(result.events.count, 1)
            try assertEqual(result.events.first?.tokens, UsageTokens(input: 50, output: 10, cacheWrite: 20, cacheRead: 30))
            try assertTrue(!result.incomplete)
            let separate = LocalUsageReader.tokens(["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": 30,
                "cache_write_input_tokens": 20, "total_tokens": 130], provider: "codex")
            try assertEqual(separate, UsageTokens(input: 70, output: 10, cacheWrite: 20, cacheRead: 30))
            try assertTrue(LocalUsageReader.tokens(["input_tokens": -1], provider: "claude") == nil)
            try assertTrue(LocalUsageReader.tokens(["input_tokens": true], provider: "claude") == nil)
        }
        failures += check("model switches and counter resets preserve distinct calls") {
            let next = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30))
            let extra = """

            {"type":"turn_context","payload":{"model":"gpt-other"}}
            {"type":"event_msg","timestamp":"\(next)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10},"last_token_usage":{"input_tokens":5,"output_tokens":5}}}}
            """
            try Data((lines + extra).utf8).write(to: file)
            let result = try LocalUsageReader.parse(file, provider: "codex", now: now)
            try assertEqual(result.events.count, 2)
            try assertEqual(Set(result.events.map(\.model)), Set(["gpt-test", "gpt-other"]))
        }
        failures += check("Claude streaming repeats keep an actual complete row") {
            let claude = root.appendingPathComponent("claude.jsonl")
            let lines = [2, 5, 3].map { output in
                #"{"type":"assistant","timestamp":"TIMESTAMP","requestId":"req","message":{"id":"msg","model":"claude-test","usage":{"input_tokens":10,"output_tokens":OUTPUT,"cache_read_input_tokens":50}}}"#
                    .replacingOccurrences(of: "TIMESTAMP", with: timestamp).replacingOccurrences(of: "OUTPUT", with: String(output))
            }.joined(separator: "\n")
            try Data(lines.utf8).write(to: claude)
            let result = try LocalUsageReader.parse(claude, provider: "claude", now: now)
            try assertEqual(result.events.count, 1)
            try assertEqual(result.events.first?.tokens.output, 5)
            try assertEqual(result.events.first?.tokens.total, 65)
        }
        failures += check("bounded line streaming resumes after an oversized record") {
            let file = root.appendingPathComponent("long.jsonl")
            try Data((String(repeating: "x", count: 70_000) + "\nvalid\n").utf8).write(to: file)
            var rows: [String] = []
            try UsageLogLines.streamLines(at: file, maxLineBytes: 100) { rows.append(String(decoding: $0, as: UTF8.self)) }
            try assertEqual(rows, ["valid"])
        }
        failures += check("line streaming resumes at an offset and can leave an unfinished tail") {
            let file = root.appendingPathComponent("resume.jsonl")
            try Data("one\ntwo\nthr".utf8).write(to: file)
            var rows: [String] = []
            let end = try UsageLogLines.streamLines(at: file, from: 4, includeTail: false) {
                rows.append(String(decoding: $0, as: UTF8.self))
            }
            try assertEqual(rows, ["two"])
            try assertEqual(end, 8)
            let full = try UsageLogLines.streamLines(at: file) { _ in }
            try assertEqual(full, 8)
        }
        failures += check("fork transcript history is not charged to the new session") {
            let fork = root.appendingPathComponent("fork.jsonl")
            let newer = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30))
            let inherited = lines.replacingOccurrences(of: #"{"id":"test-session"}"#,
                with: #"{"id":"child","parent_thread_id":"parent","timestamp":"STAMP"}"#.replacingOccurrences(of: "STAMP", with: newer))
            try Data(inherited.utf8).write(to: fork)
            try assertTrue(LocalUsageReader.parse(fork, provider: "codex", now: now).events.isEmpty)
        }
        failures += check("period totals respect local midnight, unknown prices and future events") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
            let now = ISO8601DateFormatter().date(from: "2026-09-12T00:30:00Z")!
            let start = calendar.startOfDay(for: now)
            let rates = ModelPrice(displayName: "Known", inputPerMillion: 1, outputPerMillion: 2,
                                   cacheCreationPerMillion: 3, cacheReadPerMillion: 0.1)
            let catalog = UsagePriceCatalog(schemaVersion: 1, generatedAt: "2026-09-12", models: ["known": rates])
            let tokens = UsageTokens(input: 100, output: 20, cacheWrite: 30, cacheRead: 500)
            let events = [LocalUsageEvent(id: "1", date: start, model: "known", tokens: tokens),
                          LocalUsageEvent(id: "2", date: start.addingTimeInterval(-1), model: "known", tokens: tokens),
                          LocalUsageEvent(id: "3", date: start, model: "new-model", tokens: tokens),
                          LocalUsageEvent(id: "4", date: now.addingTimeInterval(1), model: "known", tokens: tokens)]
            let today = LocalUsageSummary.make(events: events, catalog: catalog, period: .today, now: now, calendar: calendar)
            try assertEqual(today.tokens.total, 1300)
            try assertEqual(today.unpricedTokens, 650)
            try assertEqual(today.dollars ?? -1, 0.00028, accuracy: 0.000001)
            try assertEqual(today.trend.reduce(0) { $0 + $1.tokens }, today.tokens.total)
            try assertTrue(catalog.price(for: "invented") == nil)
            let week = LocalUsageSummary.make(events: events, catalog: catalog, period: .week, now: now, calendar: calendar)
            try assertEqual(week.tokens.total, 1950)
            try assertEqual(week.trend.count, 7)
        }
        let archiveURL = root.appendingPathComponent("archive")
        let archive = LocalUsageArchive(directory: archiveURL)
        let first = await archive.refresh(provider: "codex", roots: [logs], now: now)
        let again = await archive.refresh(provider: "codex", roots: [logs], now: now)
        try? FileManager.default.removeItem(at: file)
        let reopened = LocalUsageArchive(directory: archiveURL)
        let retained = await reopened.refresh(provider: "codex", roots: [logs], now: now)
        failures += check("history survives rescans, deleted source logs and app restart") {
            try assertEqual(first.events.count, 2)
            try assertEqual(again.events.count, 2)
            try assertEqual(retained.events.count, 2)
            try assertTrue(retained.notice == nil)
        }
        let damaged = archiveURL.appendingPathComponent("claude.json")
        try? Data("do not overwrite".utf8).write(to: damaged)
        let corrupt = await reopened.refresh(provider: "claude", roots: [], now: now)
        failures += check("corrupt history is preserved and reported") {
            try assertTrue(corrupt.notice != nil)
            try assertEqual(String(contentsOf: damaged, encoding: .utf8), "do not overwrite")
        }
        let olderArchive = LocalUsageArchive.Archive(
            events: ["kept": LocalUsageEvent(id: "kept", date: now.addingTimeInterval(-60), model: "m",
                                             tokens: UsageTokens(input: 1, output: 1))])
        var olderObject = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(olderArchive))) as? [String: Any] ?? [:]
        olderObject.removeValue(forKey: "incompleteFiles")
        try? JSONSerialization.data(withJSONObject: olderObject)
            .write(to: archiveURL.appendingPathComponent("older-schema.json"))
        let olderRead = await LocalUsageArchive(directory: archiveURL).cached(provider: "grok", scope: "older-schema")
        failures += check("history saved before a defaulted archive field is still readable") {
            try assertEqual(olderRead.events.map(\.id), ["kept"])
            try assertTrue(olderRead.notice == nil, "got \(olderRead.notice ?? "")")
        }
        let notDirectory = root.appendingPathComponent("not-directory")
        try? Data("preserve".utf8).write(to: notDirectory)
        try? Data(lines.utf8).write(to: file)
        let blocked = LocalUsageArchive(directory: notDirectory)
        let unsaved = await blocked.refresh(provider: "codex", roots: [logs], now: now)
        failures += check("a failed save still returns current usage") {
            try assertEqual(unsaved.events.count, 1)
            try assertTrue(unsaved.notice?.contains("could not be saved") == true)
            try assertEqual(String(contentsOf: notDirectory, encoding: .utf8), "preserve")
        }
        let scopedA = await archive.refresh(provider: "codex", roots: [logs], scope: "codex-account-a", now: now)
        let scopedB = await archive.refresh(provider: "codex", roots: [], scope: "codex-account-b", now: now)
        let scopedReopen = LocalUsageArchive(directory: archiveURL)
        let savedA = await scopedReopen.cached(provider: "codex", scope: "codex-account-a")
        let savedB = await scopedReopen.cached(provider: "codex", scope: "codex-account-b")
        let machine = await scopedReopen.cached(provider: "codex")
        let orca = root.appendingPathComponent("Library/Application Support/orca")
        let orcaPaths = ["codex-accounts/a/home/sessions", "codex-runtime-home/home/sessions",
                         "claude-accounts/b/auth/projects"]
        for path in orcaPaths {
            try? FileManager.default.createDirectory(at: orca.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let bridged = orca.appendingPathComponent(orcaPaths[0]).appendingPathComponent("rollout-test.jsonl")
        try? FileManager.default.linkItem(at: file, to: bridged)
        let discovered = LocalUsageStore.orcaRoots(provider: "codex", home: root)
        let orcaHistory = await archive.refresh(provider: "codex", roots: [logs] + discovered,
                                               scope: "orca-machine", now: now)
        failures += check("Mac history discovers Orca homes and counts bridged transcripts once") {
            try assertEqual(Set(discovered.map { $0.resolvingSymlinksInPath() }),
                            Set(orcaPaths.prefix(2).map { orca.appendingPathComponent($0).resolvingSymlinksInPath() }))
            try assertEqual(LocalUsageStore.orcaRoots(provider: "claude", home: root).map { $0.resolvingSymlinksInPath() },
                            [orca.appendingPathComponent(orcaPaths[2]).resolvingSymlinksInPath()])
            try assertTrue(LocalUsageStore.orcaRoots(provider: "grok", home: root).isEmpty)
            try assertEqual(orcaHistory.events.count, 1)
            try assertEqual(orcaHistory.events.first?.tokens.total, 110)
            try assertTrue(orcaHistory.notice == nil)
        }
        failures += check("account history never inherits another account or machine totals") {
            try assertEqual(scopedA.events.count, 1)
            try assertEqual(scopedB.events.count, 0)
            try assertEqual(savedA.events.count, 1)
            try assertEqual(savedB.events.count, 0)
            try assertEqual(machine.events.count, 2)
        }
        let grokFile = logs.appendingPathComponent("updates.jsonl")
        let grokLine = #"{"timestamp":"STAMP","_meta":{"promptId":"prompt","modelUsage":{"grok-test":{"inputTokens":5000,"outputTokens":200,"cacheReadTokens":4000,"cacheCreationTokens":100}}}}"#
            .replacingOccurrences(of: "STAMP", with: timestamp)
        failures += check("Grok normalizes input and deduplicates final prompt reports") {
            try Data((grokLine + "\n" + grokLine + "\n").utf8).write(to: grokFile)
            let result = try GrokUsageReader.read(grokFile)
            try assertEqual(result.events.count, 1)
            try assertEqual(result.events.first?.tokens, UsageTokens(input: 900, output: 200, cacheWrite: 100, cacheRead: 4000))
            let incomplete = grokLine.replacingOccurrences(of: "\"promptId\"", with: "\"usageIsIncomplete\":true,\"promptId\"")
            try assertTrue(GrokUsageReader.parse(Data(incomplete.utf8)).isEmpty)
            let current = #"{"timestamp":1789089113,"params":{"sessionId":"s","_meta":{"eventId":"e"},"update":{"sessionUpdate":"turn_completed","prompt_id":"p","usage":{"modelUsage":{"grok-4.6-build":{"inputTokens":5000,"outputTokens":200,"cachedReadTokens":4000,"costUsdTicks":9474185000}}}}}}"#
            let event = GrokUsageReader.parse(Data(current.utf8)).first
            try assertEqual(event?.tokens, UsageTokens(input: 1000, output: 200, cacheRead: 4000))
            try assertEqual(event?.reportedDollars ?? -1, 0.9474185, accuracy: 0.0000001)
            let summary = LocalUsageSummary.make(events: [event!], catalog: nil, period: .month,
                now: Date(timeIntervalSince1970: 1789089213))
            try assertEqual(summary.dollars ?? -1, 0.9474185, accuracy: 0.0000001)
            try assertEqual(summary.unpricedTokens, 0)
        }
        failures += check("Gemini introductory prices follow call date, not today's date") {
            let catalog = UsagePriceCatalog(schemaVersion: 1, generatedAt: "2026-09-12", models: [:])
            let before = catalog.price(for: "gemini-3.7-flash", at: Date(timeIntervalSince1970: 1_798_761_599))
            let after = catalog.price(for: "gemini-3.7-flash", at: Date(timeIntervalSince1970: 1_798_761_600))
            try assertEqual(before?.inputPerMillion ?? -1, 0.75, accuracy: 0.001)
            try assertEqual(after?.inputPerMillion ?? -1, 1.5, accuracy: 0.001)
        }
        let agyFile = logs.appendingPathComponent("agy.db")
        var db: OpaquePointer?
        failures += check("Agy reads one generation across multiple steps without double-counting thinking") {
            try assertEqual(sqlite3_open(agyFile.path, &db), SQLITE_OK)
            let metadata = bytes(1, integer(1, Int(now.addingTimeInterval(-60).timeIntervalSince1970)))
            let sql = """
            CREATE TABLE steps(idx INTEGER, metadata BLOB);
            CREATE TABLE gen_metadata(idx INTEGER, data BLOB);
            INSERT INTO steps VALUES(1, X'\(hex(metadata))'),(2, X'\(hex(metadata))');
            INSERT INTO gen_metadata VALUES(0, X'\(hex(generation(id: "call-1")))');
            """
            try assertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            let result = try AntigravityUsageReader.read(agyFile)
            try assertEqual(result.events.count, 1)
            try assertEqual(result.events.first?.tokens, UsageTokens(input: 1000, output: 200, cacheRead: 4000))
            try assertEqual(result.events.first?.model, "gemini-test")
            try assertTrue(UsageProtobufFields(Data([10, 8, 1])) == nil)
            try assertTrue(UsageProtobufFields(Data(repeating: 255, count: 12)) == nil)
        }
        let agyFirst = await archive.refresh(provider: "agy", roots: [logs], now: now)
        // A committed WAL write need not change the main DB's mtime or size.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO gen_metadata VALUES(1, X'\(hex(generation(id: "call-2")))');", nil, nil, nil)
        let agySecond = await archive.refresh(provider: "agy", roots: [logs], now: now)
        sqlite3_close(db)
        let grokSaved = await archive.refresh(provider: "grok", roots: [logs], now: now)
        try? FileManager.default.removeItem(at: agyFile)
        try? FileManager.default.removeItem(at: grokFile)
        let agyRetained = await archive.refresh(provider: "agy", roots: [logs], now: now)
        let grokRetained = await archive.refresh(provider: "grok", roots: [logs], now: now)
        failures += check("Grok and Agy feed persistent history; SQLite WAL updates stay visible") {
            try assertEqual(agyFirst.events.count, 1)
            try assertEqual(agySecond.events.count, 2)
            try assertEqual(agyRetained.events.count, 2)
            try assertEqual(grokSaved.events.count, 1)
            try assertEqual(grokRetained.events.count, 1)
        }
        let growingDir = root.appendingPathComponent("growing")
        try? FileManager.default.createDirectory(at: growingDir, withIntermediateDirectories: true)
        let growing = growingDir.appendingPathComponent("updates.jsonl")
        let growArchiveURL = root.appendingPathComponent("grow-archive")
        let growArchive = LocalUsageArchive(directory: growArchiveURL)
        func grokPrompt(_ id: String) -> String { grokLine.replacingOccurrences(of: "\"prompt\"", with: "\"\(id)\"") + "\n" }
        func inode(_ url: URL) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]) as? Int
        }
        try? Data(grokPrompt("p1").utf8).write(to: growing)
        let growFirst = await growArchive.refresh(provider: "grok", roots: [growingDir], scope: "grow", now: now)
        let savedGrow = growArchiveURL.appendingPathComponent("grow.json")
        let inodeAfterFirst = inode(savedGrow)
        let growIdle = await growArchive.refresh(provider: "grok", roots: [growingDir], scope: "grow", now: now)
        let inodeAfterIdle = inode(savedGrow)
        // Damage the already-read first line in place (same inode, same length), then append.
        let firstLength = grokPrompt("p1").utf8.count
        if let handle = try? FileHandle(forWritingTo: growing) {
            try? handle.write(contentsOf: Data(("{\"modelUsage\"" + String(repeating: "x", count: firstLength - 14) + "\n").utf8))
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(grokPrompt("p2").utf8))
            try? handle.close()
        }
        let growAppended = await growArchive.refresh(provider: "grok", roots: [growingDir], scope: "grow", now: now)
        // A replaced log (new inode, smaller) is read from the start again.
        try? FileManager.default.removeItem(at: growing)
        try? Data(grokPrompt("p3").utf8).write(to: growing)
        let growReplaced = await growArchive.refresh(provider: "grok", roots: [growingDir], scope: "grow", now: now)
        failures += check("archive reads only appended lines of a growing log") {
            try assertEqual(growFirst.events.count, 1)
            try assertEqual(growIdle.events.count, 1)
            try assertEqual(Set(growAppended.events.map(\.id)), ["grok:p1:grok-test", "grok:p2:grok-test"])
            try assertTrue(growAppended.notice == nil, "re-read the old first line: \(growAppended.notice ?? "")")
            try assertEqual(growReplaced.events.count, 3)
        }
        // A line written during a refresh can carry a timestamp after that refresh's `now`.
        let lateDir = root.appendingPathComponent("late")
        try? FileManager.default.createDirectory(at: lateDir, withIntermediateDirectories: true)
        let lateLine = grokPrompt("late").replacingOccurrences(
            of: timestamp, with: ISO8601DateFormatter().string(from: now.addingTimeInterval(30)))
        try? Data(lateLine.utf8).write(to: lateDir.appendingPathComponent("updates.jsonl"))
        let lateEarly = await growArchive.refresh(provider: "grok", roots: [lateDir], scope: "late", now: now)
        let lateAfter = await growArchive.refresh(provider: "grok", roots: [lateDir], scope: "late",
                                                  now: now.addingTimeInterval(60))
        failures += check("a line newer than the refresh is read again later, not skipped for good") {
            try assertEqual(lateEarly.events.count, 0)
            try assertEqual(lateAfter.events.map(\.id), ["grok:late:grok-test"])
        }
        failures += check("an unchanged refresh does not rewrite the archive") {
            try assertTrue(inodeAfterFirst != nil)
            try assertEqual(inodeAfterIdle, inodeAfterFirst)
        }
        var aged = LocalUsageArchive.Archive(events: [
            "old": LocalUsageEvent(id: "old", date: now.addingTimeInterval(-Double(LocalUsageArchive.retentionDays + 10) * 86_400), model: "m",
                                   tokens: UsageTokens(input: 1, output: 1)),
            "recent": LocalUsageEvent(id: "recent", date: now.addingTimeInterval(-10 * 86_400), model: "m",
                                      tokens: UsageTokens(input: 1, output: 1))])
        aged.files["/gone/updates.jsonl"] = .init(modified: now, size: 1)
        aged.incompleteFiles = ["/gone/updates.jsonl"]
        try? JSONEncoder().encode(aged).write(to: growArchiveURL.appendingPathComponent("aged.json"))
        let prunedSnapshot = await LocalUsageArchive(directory: growArchiveURL)
            .refresh(provider: "grok", roots: [], scope: "aged", now: now)
        let prunedFile = try? JSONDecoder().decode(LocalUsageArchive.Archive.self,
            from: Data(contentsOf: growArchiveURL.appendingPathComponent("aged.json")))
        failures += check("archive keeps retentionDays of events and forgets vanished files") {
            try assertEqual(prunedSnapshot.events.map(\.id), ["recent"])
            try assertTrue(prunedSnapshot.notice == nil, "got \(prunedSnapshot.notice ?? "")")
            try assertEqual(prunedFile?.events.keys.sorted(), ["recent"])
            try assertEqual(prunedFile?.files.isEmpty, true)
        }

        failures += check("live account telemetry joins provider identity and excludes other accounts") {
            let directory = root.appendingPathComponent("tracking")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var db: OpaquePointer?
            try assertEqual(sqlite3_open(directory.appendingPathComponent("account-usage.sqlite").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let a = AccountUsageReader.identity(provider: "codex", account: "a")!
            let b = AccountUsageReader.identity(provider: "codex", account: "b")!
            try assertTrue(a != b)
            try assertEqual(a, AccountUsageReader.identity(provider: "codex", account: "A"))
            try assertEqual(a, "22c77d32389abfdb529c5ad70e72da2e092773971d842e82d94d8a39e78ec629")
            let sql = """
            CREATE TABLE usage_events(provider TEXT,identity TEXT,event_id TEXT,timestamp REAL,model TEXT,input INTEGER,output INTEGER,cache_write INTEGER,cache_read INTEGER,dollars REAL);
            INSERT INTO usage_events VALUES('codex','\(a)','same-call',\(now.timeIntervalSince1970 - 1),'model-a',10,2,0,5,NULL);
            INSERT INTO usage_events VALUES('codex','\(b)','same-call',\(now.timeIntervalSince1970 - 1),'model-b',100,20,0,50,0.1);
            """
            try assertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            let first = AccountUsageReader.read(provider: "codex", identity: a, directory: directory, now: now)
            let second = AccountUsageReader.read(provider: "codex", identity: b, directory: directory, now: now)
            try assertEqual(first.events.count, 1)
            try assertEqual(first.events.first?.tokens.total, 17)
            try assertEqual(second.events.first?.tokens.total, 170)
            try assertTrue(first.events.first?.reportedDollars == nil)
            try assertTrue(AccountUsageReader.read(provider: "codex", identity: nil, directory: directory).notice != nil)
            // The Mac total is the union of the same captured records, even for
            // identities no longer configured locally. Never substitute transcripts.
            let captured = AccountUsageReader.readAccounts(provider: "codex", directory: directory, now: now)
            try assertTrue(captured.notice == nil)
            try assertEqual(captured.accounts[a], first.events)
            try assertEqual(captured.accounts[b], second.events)
            let all = captured.accounts.values.flatMap { $0 }
            for period in UsagePeriod.allCases {
                let total = LocalUsageSummary.make(events: all, catalog: nil, period: period, now: now)
                let account = LocalUsageSummary.make(events: second.events, catalog: nil, period: period, now: now)
                try assertEqual(total.tokens.total, 187)
                try assertTrue(total.tokens.total >= account.tokens.total)
                try assertEqual(total.dollars, account.dollars)
            }
            try assertTrue(AccountUsageReader.readAccounts(provider: "claude", directory: directory, now: now).accounts.isEmpty)
            try assertTrue(LocalUsageStore.sourceKey(provider: "codex", accountID: nil)
                != LocalUsageStore.sourceKey(provider: "codex", accountID: nil, transcriptHistory: true))
        }
        failures += check("captured spend prices rows stored without a price from the catalog") {
            let directory = root.appendingPathComponent("tracking-unpriced")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var db: OpaquePointer?
            try assertEqual(sqlite3_open(directory.appendingPathComponent("account-usage.sqlite").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let t = now.timeIntervalSince1970
            // Codex rows arrive with dollars NULL; the collector prices Claude rows itself.
            let sql = """
            CREATE TABLE usage_events(provider TEXT,identity TEXT,event_id TEXT,timestamp REAL,model TEXT,input INTEGER,output INTEGER,cache_write INTEGER,cache_read INTEGER,dollars REAL);
            INSERT INTO usage_events VALUES('codex','a','e1',\(t - 10),'known',1000000,0,0,0,NULL);
            INSERT INTO usage_events VALUES('codex','a','e2',\(t - 10),'known',0,500000,0,2000000,NULL);
            INSERT INTO usage_events VALUES('codex','a','e3',\(t - 10),'known',0,0,0,0,0.25);
            INSERT INTO usage_events VALUES('codex','a','e4',\(t - 10),'unpriced-model',1000000,0,0,0,NULL);
            INSERT INTO usage_events VALUES('codex','b','e5',\(t - 10),'known',1000000,0,0,0,NULL);
            INSERT INTO usage_events VALUES('codex','a','e6',\(t - 1000),'known',1000000,0,0,0,NULL);
            """
            try assertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            let rates = ModelPrice(displayName: nil, inputPerMillion: 1, outputPerMillion: 2,
                                   cacheCreationPerMillion: 3, cacheReadPerMillion: 0.1)
            let catalog = UsagePriceCatalog(schemaVersion: 1, generatedAt: "test", models: ["known": rates])
            func spend(_ catalog: UsagePriceCatalog?) -> Double? {
                AccountUsageReader.capturedDollars(provider: "codex", identity: "a", from: now.addingTimeInterval(-60),
                                                   to: now, directory: directory, catalog: catalog)
            }
            // 1.00 input + (1.00 output + 0.20 cache read) + 0.25 recorded; unknown model stays out.
            try assertEqual(spend(catalog) ?? -1, 2.45, accuracy: 1e-9)
            // Without a catalog only recorded prices count: still a lower bound, never a guess.
            try assertEqual(spend(nil) ?? -1, 0.25, accuracy: 1e-9)
        }

        return failures
    }

    // Isolated protobuf/SQLite fixture, matching the source reader's wire contract.
    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while value >= 128 { out.append(UInt8(value & 127) | 128); value >>= 7 }
        out.append(UInt8(value))
        return out
    }
    private static func integer(_ field: Int, _ value: Int) -> Data {
        varint(UInt64(field << 3)) + varint(UInt64(value))
    }
    private static func bytes(_ field: Int, _ value: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func generation(id: String) -> Data {
        let usage = integer(2, 1000) + integer(3, 200) + integer(5, 4000)
            + integer(9, 120) + integer(10, 80) + bytes(7, Data(id.utf8))
        return bytes(1, bytes(4, usage) + bytes(19, Data("gemini-test".utf8))) + bytes(2, Data([1, 2]))
    }
}
