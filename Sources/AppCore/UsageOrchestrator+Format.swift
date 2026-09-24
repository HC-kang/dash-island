import Foundation

extension UsageOrchestrator {
    // MARK: - Captions and formatting

    /// Map used-fraction through display mode. Result always 0...1.
    nonisolated static func displayFraction(
        used: Double,
        mode: PreferencesStore.DisplayMode
    ) -> Double {
        let u = min(1, max(0, used))
        switch mode {
        case .used: return u
        case .remaining: return 1 - u
        }
    }

    nonisolated static func tint(for vendorID: VendorID) -> VendorTint {
        switch vendorID {
        case "claude": return .claude
        case "codex": return .codex
        case "grok": return .grok
        case "agy": return .agy
        default: return .neutral
        }
    }

    /// Short under-widget line (truncated by the cell).
    nonisolated static func caption(for error: UsageError?, vendorID: VendorID = "") -> String? {
        guard let error else { return nil }
        switch error {
        case .authRequired:
            switch vendorID {
            case "claude": return String(localized: "reconnect account")
            case "codex": return String(localized: "reauth: codex")
            case "grok": return String(localized: "reauth: grok")
            case "agy": return String(localized: "reauth: agy")
            default: return String(localized: "reauth needed")
            }
        case .rateLimited:
            return vendorID == "claude" ? String(localized: "oauth rate limited") : String(localized: "rate limited")
        case .network(let message):
            return message.isEmpty ? String(localized: "network error") : message
        case .parse(let message):
            return message.isEmpty ? String(localized: "parse error") : message
        case .unavailable:
            // One classification (UnavailableReason) for severity and copy (core-10).
            switch error.unavailableReason ?? .temporary {
            case .needsLogin: return String(localized: "need browser login")
            // Self-scheduled retry: rings stay, no red line. Notice/tooltip carry the age.
            case .refreshPending: return nil
            case .tokenQuiet, .temporary: return String(localized: "token quiet")
            }
        }
    }

    /// The one command that signs this account in again from a terminal.
    nonisolated static func loginCommand(vendorID: VendorID, home: String) -> String {
        switch vendorID {
        case "claude": return "CLAUDE_CONFIG_DIR='\(home)' claude auth login --claudeai"
        case "codex": return "CODEX_HOME='\(home)' codex login"
        case "grok": return "GROK_HOME='\(home)' grok login --oauth"
        case "agy": return "HOME='\(home)' agy"
        default: return ""
        }
    }

    /// Full explanation for the downward hover tooltip.
    nonisolated static func detailCaption(
        for error: UsageError?,
        vendorID: VendorID,
        credentialRef: CredentialRef
    ) -> String? {
        guard let error else { return nil }
        let home = CredentialStore.directoryURL(for: credentialRef).path
        switch error {
        case .authRequired:
            switch vendorID {
            case "claude":
                return String(localized: """
                Claude rejected this account’s token (invalid login or missing user:profile).
                setup-token cannot read usage — use full browser OAuth.
                Widget menu → Reauthenticate this account only (other accounts stay put).
                Or: CLAUDE_CONFIG_DIR='\(home)' claude auth login --claudeai
                """)
            case "codex":
                return String(localized: """
                Codex session rejected. Widget menu → Reauthenticate, or:
                CODEX_HOME='\(home)' codex login
                """)
            case "grok":
                return String(localized: """
                Grok session rejected. Widget menu → Reauthenticate, or:
                GROK_HOME='\(home)' grok login --oauth
                """)
            case "agy":
                return String(localized: """
                Antigravity session rejected. Widget menu → Reauthenticate, or:
                HOME='\(home)' agy
                """)
            default:
                return String(localized: "Reauthenticate from the widget menu.")
            }
        case .rateLimited:
            if vendorID == "claude" {
                return String(localized: """
                Claude OAuth token host is rate-limited (not your 5h/wk usage quota).
                Long quiet window — last-good rings stay. No re-login required yet.
                Each account uses its own credentials file; reconnect only if this never recovers.
                """)
            }
            return String(localized: """
            Vendor rate-limited (usage API or OAuth token refresh).
            Long quiet window; last-good numbers stay on the rings. No re-login needed yet.
            """)
        case .network(let message):
            return message.isEmpty
                ? String(localized: "Network error — will retry on next poll. Last-good rings stay if present.")
                : message
        case .parse(let message):
            return message.isEmpty ? String(localized: "Could not parse vendor response.") : message
        case .unavailable(let message):
            switch error.unavailableReason ?? .temporary {
            case .needsLogin:
                return String(localized: """
                \(message)
                Widget menu → Reauthenticate (browser login for this account only).
                \(loginCommand(vendorID: vendorID, home: home))
                """)
            case .refreshPending:
                return String(localized: """
                \(message)
                Soft failure — will retry on the next poll. Last-good rings stay if present.
                """)
            case .tokenQuiet, .temporary:
                return String(localized: """
                \(message.isEmpty ? String(localized: "Temporarily unavailable.") : message)
                Soft failure: last-good usage stays on the rings. Not a full reconnect yet.
                If this persists for hours, widget menu → Reauthenticate this account only.
                """)
            }
        }
    }

    /// Relative age: `3m ago`, `2h ago`, `1d ago`.
    nonisolated static func formatAgeAgo(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let total = Int(seconds.rounded(.down))
        if total < 60 { return String(localized: "<1m ago") }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let mins = (total % 3_600) / 60
        if days > 0 {
            return hours > 0 ? String(localized: "\(days)d \(hours)h ago") : String(localized: "\(days)d ago")
        }
        if hours > 0 {
            return mins > 0 ? String(localized: "\(hours)h \(mins)m ago") : String(localized: "\(hours)h ago")
        }
        return String(localized: "\(mins)m ago")
    }

    /// Compact age for under-widget captions: `3m`, `2h`, `1d`.
    nonisolated static func formatCompactAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let total = Int(seconds.rounded(.down))
        if total < 60 { return String(localized: "<1m") }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let mins = (total % 3_600) / 60
        if days > 0 { return String(localized: "\(days)d") }
        if hours > 0 { return String(localized: "\(hours)h") }
        return String(localized: "\(mins)m")
    }

    /// Freshness line for a healthy widget. Without this a 14-minute-old ring and
    /// a one-second-old ring look identical, which is what made the numbers feel
    /// wrong long before the poll interval was the suspect.
    /// `projectedFraction` is already display-mode mapped, so this line agrees with
    /// the usage rows above it instead of quietly reporting Used inside Remaining.
    nonisolated static func formatFreshnessLine(
        lastSuccessAt: Date?,
        projectedFraction: Double?,
        now: Date = Date()
    ) -> String? {
        guard let lastSuccessAt else { return nil }
        let age = formatAgeAgo(since: lastSuccessAt, now: now)
        guard let projectedFraction else { return String(localized: "checked \(age)") }
        let percent = Int((min(1, max(0, projectedFraction)) * 100).rounded())
        return String(localized: "checked \(age) · ≈\(percent)% est. from local calls")
    }

    /// Timing lines for error tips: checked / retry / last ok.
    nonisolated static func formatErrorTimingLines(
        lastCheckedAt: Date?,
        lastSuccessAt: Date?,
        retryAt: Date?,
        now: Date = Date()
    ) -> [String] {
        var lines: [String] = []
        if let checked = lastCheckedAt {
            lines.append(String(localized: "checked \(formatAgeAgo(since: checked, now: now))"))
        }
        if let retry = retryAt, retry > now,
           let remaining = formatResetRemaining(until: retry, now: now)
        {
            lines.append(String(localized: "retry in \(remaining)"))
        } else if lastCheckedAt != nil, retryAt == nil {
            lines.append(String(localized: "retry on next poll"))
        }
        if let ok = lastSuccessAt {
            lines.append(String(localized: "last ok \(formatAgeAgo(since: ok, now: now))"))
        }
        return lines
    }

    /// Hover rows: primary + secondary + tertiary rings, then remaining extras.
    nonisolated static func hoverWindows(
        snapshot: UsageSnapshot?,
        mode: PreferencesStore.DisplayMode
    ) -> [HoverWindowLine] {
        guard let snapshot else { return [] }
        var lines: [HoverWindowLine] = []
        lines.append(windowLine(window: snapshot.primary, mode: mode))
        if let secondary = snapshot.secondary {
            lines.append(windowLine(window: secondary, mode: mode))
        }
        if let tertiary = snapshot.tertiary {
            lines.append(windowLine(window: tertiary, mode: mode))
        }
        for extra in snapshot.extras {
            lines.append(windowLine(window: extra, mode: mode))
        }
        return lines
    }

    nonisolated private static func windowLine(
        window: WindowUsage,
        mode: PreferencesStore.DisplayMode
    ) -> HoverWindowLine {
        let label = window.displayLabel
        let usage: String
        if let used = window.usedTokens, let limit = window.limitTokens, limit > 0 {
            usage = "\(formatTokens(used)) / \(formatTokens(limit))"
        } else {
            let fraction = displayFraction(used: window.usedFraction, mode: mode)
            let pct = Int((fraction * 100).rounded())
            usage = "\(pct)%"
        }
        return HoverWindowLine(label: label, usage: usage, resetAt: window.resetAt)
    }

    /// Compact remaining time until reset: `1d 5h`, `5h 12m`, `42m`, `<1m`.
    nonisolated static func formatResetRemaining(
        until resetAt: Date,
        now: Date = Date()
    ) -> String? {
        let seconds = resetAt.timeIntervalSince(now)
        if seconds <= 0 { return String(localized: "now") }
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let mins = (total % 3_600) / 60
        if days > 0 {
            return hours > 0 ? String(localized: "\(days)d \(hours)h") : String(localized: "\(days)d")
        }
        if hours > 0 {
            return mins > 0 ? String(localized: "\(hours)h \(mins)m") : String(localized: "\(hours)h")
        }
        if mins > 0 { return String(localized: "\(mins)m") }
        return String(localized: "<1m")
    }

    /// Compact token count for hover (k / m).
    nonisolated static func formatTokens(_ n: Int64) -> String {
        let v = Double(n)
        if n < 1_000 {
            return "\(n)"
        }
        if n < 10_000 {
            return String(format: "%.1fk", v / 1_000)
        }
        if n < 1_000_000 {
            return String(format: "%.0fk", v / 1_000)
        }
        if n < 10_000_000 {
            return String(format: "%.1fm", v / 1_000_000)
        }
        return String(format: "%.0fm", v / 1_000_000)
    }
}
