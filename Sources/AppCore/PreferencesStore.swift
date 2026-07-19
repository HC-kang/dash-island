import Combine
import Foundation

/// Global user preferences (UserDefaults only).
@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    /// Allowed poll intervals: 5 / 15 / 30 minutes.
    nonisolated static let allowedPollSeconds: [Int] = [300, 900, 1800]

    enum DisplayMode: String, CaseIterable, Equatable, Sendable {
        /// Rings and center show used fraction (0 → 100%).
        case used
        /// Rings and center show remaining fraction (100% → 0).
        case remaining
    }

    private enum Keys {
        static let pollSeconds = "DashIsland.pollSeconds"
        static let displayMode = "DashIsland.displayMode"
    }

    /// Poll cadence in seconds. Always one of `allowedPollSeconds`.
    @Published var pollSeconds: Int {
        didSet {
            let clamped = Self.clampPoll(pollSeconds)
            if clamped != pollSeconds {
                pollSeconds = clamped
                return
            }
            UserDefaults.standard.set(pollSeconds, forKey: Keys.pollSeconds)
        }
    }

    /// Used vs remaining for ring/center mapping.
    @Published var displayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode)
        }
    }

    init(defaults: UserDefaults = .standard) {
        let rawPoll = defaults.object(forKey: Keys.pollSeconds) as? Int
        self.pollSeconds = Self.clampPoll(rawPoll ?? 300)

        let rawMode = defaults.string(forKey: Keys.displayMode) ?? ""
        self.displayMode = DisplayMode(rawValue: rawMode) ?? .used
    }

    nonisolated static func clampPoll(_ value: Int) -> Int {
        allowedPollSeconds.contains(value) ? value : 300
    }
}
