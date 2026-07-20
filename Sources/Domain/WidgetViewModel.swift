import Foundation

/// One hover tooltip row: usage + optional reset countdown.
struct HoverWindowLine: Equatable, Sendable {
    /// Window kind label (`5h` / `wk` / `mo`).
    var label: String
    /// Usage text (`18%` or `28k / 150k`).
    var usage: String
    /// When this window resets; live-formatted in the tooltip.
    var resetAt: Date?
}

/// Presentation-ready account widget state. Views render only this model.
struct WidgetViewModel: Identifiable, Equatable, Sendable {
    var id: AccountID
    var title: String
    /// Vendor key for logo badge (`claude` / `codex` / `grok`).
    var vendorID: VendorID
    var tint: VendorTint
    /// Primary ring fraction after display-mode mapping (0...1).
    var primaryFraction: Double
    var secondaryFraction: Double?
    /// Raw used fraction 0...1 (never flipped by Remaining mode) — for hot chrome.
    var usedPrimaryFraction: Double
    var centerPercent: Int
    /// Raw burn ratio from `BurnRate` (not yet needle-mapped).
    var burnRatio: Double
    /// API Δ vs local session activity (hover honesty).
    var burnSource: BurnSignalSource = .none
    /// Structured hover rows (usage + reset). Prefer over legacy `hoverLines`.
    var hoverWindows: [HoverWindowLine]
    var errorCaption: String?
    /// Soft notice (token expiring, etc.) — not a hard error.
    var noticeCaption: String? = nil
    /// No successful sample yet — show quiet loading skeleton instead of 0%.
    var isAwaitingFirstSample: Bool

    /// Flat strings for accessibility / demos.
    var hoverLines: [String] {
        var lines: [String] = []
        for row in hoverWindows {
            if let resetAt = row.resetAt,
               let reset = UsageOrchestrator.formatResetRemaining(until: resetAt)
            {
                lines.append("\(row.label)  \(row.usage)  ·  \(reset)")
            } else {
                lines.append("\(row.label)  \(row.usage)")
            }
        }
        if let hint = burnSource.hoverHint, burnRatio > 0.03 {
            lines.append(hint)
        }
        if let noticeCaption, !noticeCaption.isEmpty {
            lines.append(noticeCaption)
        }
        return lines
    }
}
