import Foundation

/// Presentation-ready account widget state. Views render only this model.
struct WidgetViewModel: Identifiable, Equatable, Sendable {
    var id: AccountID
    var title: String
    var tint: VendorTint
    /// Primary ring fraction after display-mode mapping (0...1).
    var primaryFraction: Double
    var secondaryFraction: Double?
    var centerPercent: Int
    /// Raw burn ratio from `BurnRate` (not yet needle-mapped).
    var burnRatio: Double
    var hoverLines: [String]
    var errorCaption: String?
}
