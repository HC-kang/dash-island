import Foundation

/// `status.json` for scripts (sketchybar, tmux, Raycast): an allowlisted
/// snapshot of what the island shows. Never holds tokens or file paths.
struct StatusExport: Encodable, Equatable {
    struct Window: Encodable, Equatable {
        var label: String
        var usedPercent: Int
        var resetAt: Date?
    }

    struct Account: Encodable, Equatable {
        /// `UUID.short`.
        var id: String
        var label: String
        var vendor: String
        /// ok / warn / error.
        var health: String
        var windows: [Window]
        var lastSuccessAt: Date?
        var stale: Bool
    }

    var version = 1
    var generatedAt: Date
    var accounts: [Account]

    static func encode(_ export: StatusExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(export)
    }

    static func make(widgets: [WidgetViewModel], now: Date) -> StatusExport {
        StatusExport(generatedAt: now, accounts: widgets.map { w in
            let windows = w.usageSnapshot.map { s in
                ([s.primary] + [s.secondary, s.tertiary].compactMap { $0 } + s.extras).filter(\.isReported)
            } ?? []
            return Account(
                id: w.id.short,
                label: w.title,
                vendor: w.vendorID,
                health: w.health.defaultLabel == "warning" ? "warn" : w.health.defaultLabel,
                windows: windows.map { Window(label: $0.displayLabel, usedPercent: IslandGlance.percent($0.usedFraction), resetAt: $0.resetAt) },
                lastSuccessAt: w.lastSuccessAt,
                stale: w.usageSnapshot?.error != nil
            )
        })
    }
}
