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

/// Traffic-light health for the widget corner dot.
enum AccountHealth: Equatable, Sendable {
    case ok
    case warn
    case error

    /// Short hover string (English, monospaced-friendly).
    var defaultLabel: String {
        switch self {
        case .ok: return "ok"
        case .warn: return "warning"
        case .error: return "error"
        }
    }

    /// Derive from account poll state **and** vendor platform status page.
    static func resolve(
        error: UsageError?,
        notice: String?,
        awaitingFirst: Bool,
        service: VendorServiceSnapshot? = nil,
        authCaption: String? = nil
    ) -> (health: AccountHealth, tooltip: String) {
        var health: AccountHealth = .ok
        var parts: [String] = []

        // Platform (status.claude.com / status.openai.com / status.x.ai).
        if let service {
            switch service.level {
            case .operational:
                break
            case .unknown:
                // Don't paint yellow solely for a failed status fetch.
                parts.append(service.summary)
            case .degraded:
                health = .warn
                parts.append(service.summary)
            case .outage:
                health = .error
                parts.append(service.summary)
            }
        }

        // Account / credentials.
        if awaitingFirst {
            health = maxHealth(health, .warn)
            parts.append("waiting for first sample")
        }
        if let error {
            switch error {
            case .authRequired:
                health = maxHealth(health, .error)
                parts.append(authCaption ?? "auth required")
            case .rateLimited:
                health = maxHealth(health, .warn)
                parts.append("rate limited")
            case .network(let m):
                health = maxHealth(health, .warn)
                parts.append(m.isEmpty ? "network error" : m)
            case .parse(let m):
                health = maxHealth(health, .error)
                parts.append(m.isEmpty ? "parse error" : m)
            case .unavailable(let m):
                health = maxHealth(health, .warn)
                parts.append(m.isEmpty ? "unavailable" : m)
            }
        }
        if let notice, !notice.isEmpty {
            health = maxHealth(health, .warn)
            parts.append(notice)
        }

        if parts.isEmpty {
            if let service, service.level == .operational {
                return (.ok, service.summary)
            }
            return (.ok, "ok")
        }
        // Prefer a single readable line; join if both service + account speak.
        let tip = parts.joined(separator: " · ")
        return (health, tip)
    }

    private static func maxHealth(_ a: AccountHealth, _ b: AccountHealth) -> AccountHealth {
        let rank: (AccountHealth) -> Int = {
            switch $0 {
            case .ok: return 0
            case .warn: return 1
            case .error: return 2
            }
        }
        return rank(a) >= rank(b) ? a : b
    }
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
    /// Optional third ring (Fable / Codex model limit / …).
    var tertiaryFraction: Double? = nil
    /// Raw used fraction 0...1 (never flipped by Remaining mode) — for hot chrome.
    var usedPrimaryFraction: Double
    var centerPercent: Int
    /// Raw burn ratio from `BurnRate` (not yet needle-mapped).
    var burnRatio: Double
    /// API Δ vs local session activity (hover honesty).
    var burnSource: BurnSignalSource = .none
    /// Session-scale EWMA (slower than needle). Hover honesty.
    var burnLongRatio: Double = 0
    /// Last usage sample that fed the needle.
    var burnSampleAt: Date? = nil
    /// Integer-% API (Claude/Codex) — needle has ±1% quant uncertainty.
    var burnQuantized: Bool = false
    /// Structured hover rows (usage + reset). Prefer over legacy `hoverLines`.
    var hoverWindows: [HoverWindowLine]
    /// Short under-widget caption (often truncated).
    var errorCaption: String?
    /// Full multi-line explanation for the downward hover tooltip.
    var detailCaption: String? = nil
    /// Soft notice (token expiring, etc.) — not a hard error.
    var noticeCaption: String? = nil
    /// Last vendor poll attempt (ok or fail) — for “checked Xm ago”.
    var lastCheckedAt: Date? = nil
    /// Last clean usage sample, if any.
    var lastSuccessAt: Date? = nil
    /// When the current 429/auth cooldown ends (auto-retry).
    var retryAt: Date? = nil
    /// No successful sample yet — show quiet loading skeleton instead of 0%.
    var isAwaitingFirstSample: Bool
    /// Corner status light.
    var health: AccountHealth = .ok
    /// Hover text for the status light.
    var healthTooltip: String = "ok"

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
        // Burn is the red needle only — no engineer debug lines for end users.
        if let detailCaption, !detailCaption.isEmpty {
            lines.append(detailCaption)
        } else if let noticeCaption, !noticeCaption.isEmpty {
            lines.append(noticeCaption)
        } else if let errorCaption, !errorCaption.isEmpty {
            lines.append(errorCaption)
        }
        return lines
    }

    /// Whether the body hover card has anything to show.
    var hasHoverBody: Bool {
        !hoverWindows.isEmpty
            || !(detailCaption ?? "").isEmpty
            || !(errorCaption ?? "").isEmpty
            || !(noticeCaption ?? "").isEmpty
    }
}
