import Combine
import Foundation
import SwiftUI

/// Global user preferences (UserDefaults only).
///
/// Poll cadence is **not** user-configurable — see `UsageOrchestrator.backgroundPollSeconds`.
/// Usage is informational; we prefer last-good snapshots over burning Claude's usage API.
@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    enum DisplayMode: String, CaseIterable, Equatable, Sendable {
        /// Rings and center show used fraction (0 → 100%).
        case used
        /// Rings and center show remaining fraction (100% → 0).
        case remaining
    }

    /// Neon-style rim accent for the island edge (compact + expanded share one).
    enum RimAccent: String, CaseIterable, Equatable, Sendable, Identifiable {
        case electric
        case cyber
        case plasma
        case toxic
        case laser
        case ultraviolet
        case magma
        case solar

        var id: String { rawValue }

        var label: String {
            switch self {
            case .electric: return "Electric"
            case .cyber: return "Cyber"
            case .plasma: return "Plasma"
            case .toxic: return "Toxic"
            case .laser: return "Laser"
            case .ultraviolet: return "UV"
            case .magma: return "Magma"
            case .solar: return "Solar"
            }
        }

        /// Saturated neon for the flowing rim highlight.
        var color: Color {
            switch self {
            case .electric: return Color(red: 0.15, green: 0.95, blue: 1.0)      // icy cyan
            case .cyber: return Color(red: 0.20, green: 1.0, blue: 0.55)       // neon mint
            case .plasma: return Color(red: 0.72, green: 0.25, blue: 1.0)      // electric violet
            case .toxic: return Color(red: 0.55, green: 1.0, blue: 0.12)       // acid lime
            case .laser: return Color(red: 1.0, green: 0.12, blue: 0.55)       // hot pink
            case .ultraviolet: return Color(red: 0.45, green: 0.35, blue: 1.0) // deep UV blue
            case .magma: return Color(red: 1.0, green: 0.22, blue: 0.08)       // neon red-orange
            case .solar: return Color(red: 1.0, green: 0.92, blue: 0.15)       // electric yellow
            }
        }
    }

    private enum Keys {
        static let displayMode = "DashIsland.displayMode"
        static let rimAccent = "DashIsland.rimAccent"
        /// Legacy split keys — ignored after single-rim migration.
        static let compactRim = "DashIsland.rimCompact"
        static let expandedRim = "DashIsland.rimExpanded"
        static let pollSeconds = "DashIsland.pollSeconds"
    }

    /// Used vs remaining for ring/center mapping.
    @Published var displayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode)
        }
    }

    /// Shared rim color for compact + expanded.
    @Published var rimAccent: RimAccent {
        didSet {
            UserDefaults.standard.set(rimAccent.rawValue, forKey: Keys.rimAccent)
        }
    }

    init(defaults: UserDefaults = .standard) {
        let rawMode = defaults.string(forKey: Keys.displayMode) ?? ""
        self.displayMode = DisplayMode(rawValue: rawMode) ?? .used

        if let raw = defaults.string(forKey: Keys.rimAccent),
           let accent = RimAccent(rawValue: raw)
        {
            self.rimAccent = accent
        } else if let legacy = defaults.string(forKey: Keys.compactRim),
                  let mapped = Self.migrateLegacyRim(legacy)
        {
            self.rimAccent = mapped
        } else {
            self.rimAccent = .electric
        }
    }

    /// Map old silver/teal-style names if someone had prefs from the brief dual-rim build.
    private static func migrateLegacyRim(_ raw: String) -> RimAccent? {
        switch raw {
        case "silver", "ice": return .electric
        case "teal": return .cyber
        case "claude", "rose": return .laser
        case "codex": return .ultraviolet
        case "grok": return .plasma
        case "amber": return .solar
        default: return RimAccent(rawValue: raw)
        }
    }
}
