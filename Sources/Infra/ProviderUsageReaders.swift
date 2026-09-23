// Adapted from codex-island (MIT), Copyright (c) 2026 Eric Park.
// See THIRD_PARTY_NOTICES.md.
import Foundation
import SQLite3

enum GrokUsageReader {
    /// `start > 0` resumes an append-only log after lines already read.
    static func read(_ file: URL, from start: Int = 0) throws -> LocalUsageReader.Result {
        var events: [String: LocalUsageEvent] = [:]
        var incomplete = false
        let readThrough = try UsageLogLines.streamLines(at: file, from: start, includeTail: start == 0) { data in
            let parsed = parse(data)
            for event in parsed { events[event.id] = event }
            if parsed.isEmpty, data.range(of: Data("modelUsage".utf8)) != nil { incomplete = true }
        }
        return LocalUsageReader.Result(events: Array(events.values), incomplete: incomplete, readThrough: readThrough)
    }

    static func parse(_ data: Data) -> [LocalUsageEvent] {
        guard let row = try? JSONDecoder().decode(Update.self, from: data) else { return [] }
        let update = row.update ?? row.params?.update
        let meta = row._meta ?? update?._meta
        guard meta?.usageIsIncomplete != true,
              let prompt = update?.prompt_id ?? meta?.promptId, !prompt.isEmpty,
              let timestamp = row.timestamp?.date ?? meta?.timestamp?.date,
              let models = update?.usage?.modelUsage ?? meta?.modelUsage ?? meta?.usage?.modelUsage else { return [] }
        if let kind = update?.sessionUpdate, kind != "turn_completed" { return [] }
        return models.compactMap { model, usage in
            guard !model.isEmpty,
                  let fullInput = usage.inputTokens, let output = usage.outputTokens else { return nil }
            let cacheRead = usage.cachedReadTokens ?? usage.cacheReadTokens ?? 0
            let cacheWrite = usage.cacheCreationTokens ?? 0
            guard [fullInput, output, cacheRead, cacheWrite].allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000 }),
                  fullInput >= cacheRead + cacheWrite, fullInput + output > 0 else { return nil }
            // ACP input includes cache; keep token buckets disjoint.
            // xAI uses 10^10 USD ticks. Keep the reported API value separate
            // from subscription billing or a model-price estimate.
            // https://docs.x.ai/developers/cost-tracking
            let cost = usage.costIsPartial != true ? usage.costUsdTicks.flatMap {
                $0.isFinite && (0...1e16).contains($0) ? $0 / 1e10 : nil
            } : nil
            return LocalUsageEvent(id: "grok:\(prompt):\(model)", date: timestamp, model: model,
                tokens: UsageTokens(input: Int64(fullInput - cacheRead - cacheWrite), output: Int64(output),
                                    cacheWrite: Int64(cacheWrite), cacheRead: Int64(cacheRead)), reportedDollars: cost)
        }
    }

    private struct Update: Decodable {
        let timestamp: Timestamp?
        let _meta: Meta?
        let update: NestedUpdate?
        let params: Parameters?
    }
    private struct NestedUpdate: Decodable {
        let _meta: Meta?
        let prompt_id: String?
        let sessionUpdate: String?
        let usage: Usage?
    }
    private struct Parameters: Decodable { let update: NestedUpdate? }
    private struct Meta: Decodable {
        let timestamp: Timestamp?
        let promptId: String?
        let usageIsIncomplete: Bool?
        let usage: Usage?
        let modelUsage: [String: ModelUsage]?
    }
    private struct Usage: Decodable { let modelUsage: [String: ModelUsage]? }
    private struct ModelUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cachedReadTokens: Int?
        let cacheCreationTokens: Int?
        let costIsPartial: Bool?
        let costUsdTicks: Double?
    }
    private struct Timestamp: Decodable {
        let date: Date?
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let parsed = formatter.date(from: text) { date = parsed; return }
                formatter.formatOptions = [.withInternetDateTime]
                date = formatter.date(from: text)
            } else if let number = try? value.decode(Double.self), number.isFinite, number > 0 {
                date = Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
            } else { date = nil }
        }
    }
}


enum AntigravityUsageReader {
    // One gen_metadata row is one model call. A call can produce several steps;
    // summing steps or transcript/chunk copies would count the same call repeatedly.
    static func record(generation: Data, stepDates: [Int: Date], fallbackID: String) -> LocalUsageEvent? {
        guard let gen = UsageProtobufFields(generation), let chat = gen.message(1),
              let usage = chat.message(4), let indices = gen.integers(2),
              let date = indices.compactMap({ stepDates[$0] }).min() else { return nil }
        let input = usage.integer(2) ?? 0
        let output = usage.integer(3) ?? 0
        let cacheWrite = usage.integer(4) ?? 0
        let cacheRead = usage.integer(5) ?? 0
        // ModelUsageStats already separates cache input and includes thinking in output.
        guard [input, output, cacheWrite, cacheRead].allSatisfy({ $0 <= 1_000_000_000 }),
              input + output + cacheWrite + cacheRead > 0 else { return nil }
        let rawModel = chat.string(19) ?? chat.string(22) ?? chat.string(21)
        let model = rawModel.flatMap { $0.isEmpty ? nil : $0 } ?? "antigravity-model-\(chat.integer(3) ?? 0)"
        let messageID = usage.string(12) ?? usage.string(7) ?? usage.string(11)
        let id = messageID.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackID
        return LocalUsageEvent(id: "agy:\(id)", date: date, model: model,
            tokens: UsageTokens(input: Int64(input), output: Int64(output),
                                cacheWrite: Int64(cacheWrite), cacheRead: Int64(cacheRead)))
    }

    private enum ReadError: Error { case database }

    static func read(_ file: URL) throws -> LocalUsageReader.Result {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw ReadError.database
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ReadError.database }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        var dates: [Int: Date] = [:]
        try rows(db, sql: "SELECT idx, metadata FROM steps") { index, data in
            if let metadata = UsageProtobufFields(data), let date = metadata.message(1)?.timestamp {
                dates[index] = date
            }
        }
        var records: [LocalUsageEvent] = []
        var skipped = 0
        try rows(db, sql: "SELECT idx, data FROM gen_metadata") { index, data in
            if let record = record(generation: data, stepDates: dates,
                                   fallbackID: "\(file.deletingPathExtension().lastPathComponent):\(index)") {
                records.append(record)
            } else if UsageProtobufFields(data)?.message(1) != nil {
                skipped += 1
            }
        }
        return LocalUsageReader.Result(events: records, incomplete: skipped > 0)
    }

    private static func rows(_ db: OpaquePointer, sql: String, consume: (Int, Data) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadError.database
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw ReadError.database }
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count <= 16_777_216, let bytes = sqlite3_column_blob(statement, 1) else { continue }
            consume(Int(sqlite3_column_int64(statement, 0)), Data(bytes: bytes, count: count))
        }
    }
}
