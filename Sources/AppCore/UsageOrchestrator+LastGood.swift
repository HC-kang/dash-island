import Foundation

extension UsageOrchestrator {
    nonisolated static func encodeLastGood(_ snapshot: UsageSnapshot) -> Data? {
        guard snapshot.error == nil, snapshot.primary.isReported else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(snapshot)
    }

    nonisolated static func decodeLastGood(_ data: Data) -> UsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let snapshot = try? decoder.decode(UsageSnapshot.self, from: data),
              snapshot.error == nil
        else { return nil }
        return snapshot
    }

    @discardableResult
    nonisolated static func saveLastGood(_ snapshot: UsageSnapshot, to url: URL) -> Bool {
        guard let data = encodeLastGood(snapshot) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    nonisolated static func loadLastGood(from url: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeLastGood(data)
    }
}
