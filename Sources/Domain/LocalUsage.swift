import Foundation

struct UsageTokens: Codable, Equatable, Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheRead: Int64 = 0
    var total: Int64 { input + output + cacheWrite + cacheRead }
    var valid: Bool { [input, output, cacheWrite, cacheRead].allSatisfy { (0...1_000_000_000_000).contains($0) } }

    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, output: a.output + b.output,
             cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }

    func contains(_ other: Self) -> Bool {
        input >= other.input && output >= other.output
            && cacheWrite >= other.cacheWrite && cacheRead >= other.cacheRead
    }
}

struct LocalUsageEvent: Codable, Equatable, Sendable {
    var id: String
    var date: Date
    var model: String
    var tokens: UsageTokens
    var reportedDollars: Double? = nil
}

struct ModelPrice: Codable, Sendable {
    var displayName: String?
    var inputPerMillion: Double
    var outputPerMillion: Double
    var cacheCreationPerMillion: Double
    var cacheReadPerMillion: Double

    var valid: Bool {
        [inputPerMillion, outputPerMillion, cacheCreationPerMillion, cacheReadPerMillion]
            .allSatisfy { $0.isFinite && (0...100_000).contains($0) }
    }

    func estimate(_ tokens: UsageTokens) -> Double {
        (Double(tokens.input) * inputPerMillion + Double(tokens.output) * outputPerMillion
            + Double(tokens.cacheWrite) * cacheCreationPerMillion + Double(tokens.cacheRead) * cacheReadPerMillion) / 1_000_000
    }
}

struct UsagePriceCatalog: Codable, Sendable {
    var schemaVersion: Int
    var generatedAt: String
    var models: [String: ModelPrice]
    var valid: Bool { schemaVersion == 1 && !models.isEmpty && models.values.allSatisfy(\.valid) }

    func price(for model: String, at date: Date = Date()) -> ModelPrice? {
        // Google API pricing verified 2026-09-12. Introductory Flash rates end
        // 2027-01-01 UTC; use call time so retained history does not reprice itself.
        // https://ai.google.dev/gemini-api/docs/pricing
        if ["gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash"].contains(model) {
            let factor = date.timeIntervalSince1970 < 1_798_761_600 ? 1.0 : 2.0
            return ModelPrice(displayName: model.replacingOccurrences(of: "gemini-", with: "Gemini ").replacingOccurrences(of: "-flash", with: " Flash"),
                inputPerMillion: 0.75 * factor, outputPerMillion: 3.75 * factor,
                cacheCreationPerMillion: 0.75 * factor, cacheReadPerMillion: 0.075 * factor)
        }
        if let exact = models[model] { return exact }
        // Only strip a documented date suffix. Never guess a model family or tier.
        let suffix = model.suffix(9)
        if suffix.first == "-", suffix.dropFirst().count == 8, suffix.dropFirst().allSatisfy(\.isNumber) {
            return models[String(model.dropLast(9))]
        }
        return nil
    }
}

enum UsagePeriod: Int, CaseIterable, Identifiable {
    case today = 1, week = 7, month = 30
    var id: Int { rawValue }
    var title: String { self == .today ? String(localized: "Today") : String(localized: "\(rawValue) days") }
}

struct ModelUsageTotal: Identifiable {
    var id: String
    var name: String
    var tokens = UsageTokens()
    var dollars: Double?
    var unpricedTokens: Int64 = 0
}

struct UsageTrendPoint: Identifiable {
    var date: Date
    var tokens: Int64
    var id: Date { date }
}

struct LocalUsageSummary {
    var models: [ModelUsageTotal]
    var trend: [UsageTrendPoint]
    var tokens: UsageTokens
    var dollars: Double?
    var unpricedTokens: Int64

    static func make(events: [LocalUsageEvent], catalog: UsagePriceCatalog?, period: UsagePeriod,
                     now: Date = Date(), calendar: Calendar = .current) -> Self {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 1 - period.rawValue, to: today)!
        let component: Calendar.Component = period == .today ? .hour : .day
        var buckets: [UsageTrendPoint] = []
        var date = start
        // Calendar arithmetic preserves DST and local date boundaries.
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        while date < end {
            buckets.append(UsageTrendPoint(date: date, tokens: 0))
            guard let next = calendar.date(byAdding: component, value: 1, to: date), next > date else { break }
            date = next
        }
        let positions = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { ($0.element.date, $0.offset) })
        var rows: [String: ModelUsageTotal] = [:]
        for event in events where event.date >= start && event.date <= now && event.tokens.valid {
            let price = catalog?.price(for: event.model, at: event.date)
            let dollars = event.reportedDollars ?? price?.estimate(event.tokens)
            var row = rows[event.model] ?? ModelUsageTotal(id: event.model,
                name: price?.displayName ?? event.model, dollars: nil)
            row.tokens = row.tokens + event.tokens
            if let dollars, dollars.isFinite, dollars >= 0 { row.dollars = (row.dollars ?? 0) + dollars }
            else { row.unpricedTokens += event.tokens.total }
            rows[event.model] = row
            if let bucket = calendar.dateInterval(of: component, for: event.date)?.start,
               let index = positions[bucket] { buckets[index].tokens += event.tokens.total }
        }
        let models = rows.values.sorted { $0.tokens.total == $1.tokens.total ? $0.id < $1.id : $0.tokens.total > $1.tokens.total }
        let priced = models.compactMap(\.dollars)
        return Self(models: models, trend: buckets,
                    tokens: models.reduce(UsageTokens()) { $0 + $1.tokens },
                    dollars: priced.isEmpty ? nil : priced.reduce(0, +),
                    unpricedTokens: models.reduce(0) { $0 + $1.unpricedTokens })
    }
}
