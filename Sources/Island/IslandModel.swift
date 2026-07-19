import SwiftUI

/// Island presentation state. Default is compact — a thin bar under the notch.
/// Expanded (gauges) only while the cursor is over the island.
@MainActor
final class IslandModel: ObservableObject {
    enum State: Equatable {
        case compact
        case expanded
    }

    @Published private(set) var state: State = .compact
    @Published private(set) var size: CGSize = IslandModel.compactSize

    static let compactSize = CGSize(width: 200, height: 40)
    /// Wide enough for 5 widgets + padding + tooltip gutter.
    static let expandedSize = CGSize(width: 600, height: 200)

    func setState(_ new: State) {
        guard new != state else { return }
        state = new
        size = new == .compact ? Self.compactSize : Self.expandedSize
    }
}
