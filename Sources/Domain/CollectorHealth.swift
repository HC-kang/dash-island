import Foundation

/// State of the local usage collector from its `collector-status.json`
/// (written by scripts/usage-collector.py). The app compares the running copy's
/// VERSION with the copy bundled in the app, so a stale install is visible.
struct CollectorHealth: Equatable, Sendable {
    enum State: Equatable, Sendable { case notConnected, outdated, quiet, active }
    var state: State
    var message: String

    static func assess(status: [String: Any]?, bundledVersion: Int?, now: Date) -> CollectorHealth {
        guard let status else {
            return .init(state: .notConnected, message: "Tracking is not connected")
        }
        let running = (status["version"] as? NSNumber)?.intValue
        if let bundledVersion, (running ?? 0) < bundledVersion {
            return .init(state: .outdated, message: "Tracking collector is out of date. Reconnect to update it.")
        }
        guard let last = (status["lastBatchAt"] as? NSNumber)?.doubleValue else {
            return .init(state: .quiet, message: "Tracking connected · no calls captured yet")
        }
        let age = now.timeIntervalSince1970 - last
        if age > 86_400 {
            return .init(state: .quiet, message: "Tracking connected · no calls for \(Int(age / 86_400))d")
        }
        return .init(state: .active, message: "Tracking active · last call \(IslandGlance.countdown(age)) ago")
    }

    static func version(inScript text: String) -> Int? {
        guard let range = text.range(of: #"(?m)^VERSION = (\d+)$"#, options: .regularExpression) else { return nil }
        return Int(text[range].split(separator: "=").last!.trimmingCharacters(in: .whitespaces))
    }
}
