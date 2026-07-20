import Combine
import Foundation

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

    private enum Keys {
        static let displayMode = "DashIsland.displayMode"
        /// Legacy key — ignored; kept so old installs don't re-write noise.
        static let pollSeconds = "DashIsland.pollSeconds"
    }

    /// Used vs remaining for ring/center mapping.
    @Published var displayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode)
        }
    }

    init(defaults: UserDefaults = .standard) {
        let rawMode = defaults.string(forKey: Keys.displayMode) ?? ""
        self.displayMode = DisplayMode(rawValue: rawMode) ?? .used
    }
}
