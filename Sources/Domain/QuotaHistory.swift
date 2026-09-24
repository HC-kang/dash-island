import Foundation

/// Used-fraction history per window label for one account, for the detail
/// panel's 7-day trend. At most one sample per 15 minutes per window (the latest
/// wins); 8 days kept, so a file stays a few KB.
struct QuotaHistory: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        var at: Date
        var used: Double
    }

    static let bucket: TimeInterval = 15 * 60
    static let retention: TimeInterval = 8 * 86_400

    var samples: [String: [Sample]] = [:]

    mutating func record(window: String, used: Double, at: Date) {
        var list = samples[window] ?? []
        let sample = Sample(at: at, used: min(max(used, 0), 1))
        if let last = list.last, at.timeIntervalSince(last.at) < Self.bucket, at >= last.at {
            list[list.count - 1] = Sample(at: last.at, used: sample.used)
        } else {
            list.append(sample)
        }
        let cutoff = at.addingTimeInterval(-Self.retention)
        samples[window] = list.filter { $0.at >= cutoff }
    }

    func series(window: String, days: Int, now: Date) -> [Sample] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return (samples[window] ?? []).filter { $0.at >= cutoff && $0.at <= now }
    }
}
