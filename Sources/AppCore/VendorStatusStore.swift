import Foundation

/// Vendor **platform** health from official status pages (not our account poll).
enum ServiceLevel: Int, Equatable, Comparable, Sendable {
    case unknown = -1
    case operational = 0
    case degraded = 1
    case outage = 2

    static func < (lhs: ServiceLevel, rhs: ServiceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var accountHealth: AccountHealth {
        switch self {
        case .operational, .unknown: return .ok
        case .degraded: return .warn
        case .outage: return .error
        }
    }
}

struct VendorServiceSnapshot: Equatable, Sendable {
    var level: ServiceLevel
    /// Short line for tooltip, e.g. "Claude: All Systems Operational".
    var summary: String
    var fetchedAt: Date
    var sourceURL: String

    static func unknown(vendor: String, reason: String = "status unavailable") -> VendorServiceSnapshot {
        VendorServiceSnapshot(
            level: .unknown,
            summary: "\(vendor): \(reason)",
            fetchedAt: Date(),
            sourceURL: ""
        )
    }
}

/// Polls official status pages slowly. Shared across accounts of the same vendor.
@MainActor
final class VendorStatusStore: ObservableObject {
    static let shared = VendorStatusStore()

    /// Fixed slow cadence — status pages are public and must not be hammered.
    nonisolated static let pollSeconds: TimeInterval = 15 * 60

    @Published private(set) var byVendor: [VendorID: VendorServiceSnapshot] = [:]

    private var timer: Timer?
    private var fetching = false
    private var started = false

    private init() {}

    func start() {
        guard !started else {
            Task { await refreshAll() }
            return
        }
        started = true
        Task { await refreshAll() }
        let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        started = false
    }

    func snapshot(for vendorID: VendorID) -> VendorServiceSnapshot? {
        byVendor[vendorID]
    }

    func refreshAll() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }

        async let claude = Self.fetchClaude()
        async let openai = Self.fetchOpenAI()
        async let grok = Self.fetchXAI()

        let (c, o, g) = await (claude, openai, grok)
        byVendor["claude"] = c
        byVendor["codex"] = o
        byVendor["grok"] = g
        NotificationCenter.default.post(name: .dashIslandVendorStatusChanged, object: nil)
    }

    // MARK: - Claude (Statuspage → status.claude.com)

    nonisolated static func fetchClaude() async -> VendorServiceSnapshot {
        await fetchStatuspage(
            url: "https://status.claude.com/api/v2/summary.json",
            vendorLabel: "Claude",
            // Prefer product surfaces we actually hit.
            preferredComponentNames: [
                "Claude API (api.anthropic.com)",
                "Claude Code",
                "claude.ai",
            ]
        )
    }

    // MARK: - OpenAI / Codex

    nonisolated static func fetchOpenAI() async -> VendorServiceSnapshot {
        await fetchStatuspage(
            url: "https://status.openai.com/api/v2/summary.json",
            vendorLabel: "OpenAI",
            preferredComponentNames: [
                "Codex API",
                "Codex in ChatGPT Desktop",
                "ChatGPT",
                "API",
            ]
        )
    }

    // MARK: - Statuspage.io shared parser

    nonisolated static func fetchStatuspage(
        url urlString: String,
        vendorLabel: String,
        preferredComponentNames: [String]
    ) async -> VendorServiceSnapshot {
        guard let url = URL(string: urlString) else {
            return .unknown(vendor: vendorLabel)
        }
        var req = URLRequest(url: url)
        req.setValue("DashIsland/1.0 (status check)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .unknown(vendor: vendorLabel, reason: "status HTTP error")
            }
            return parseStatuspage(
                data: data,
                vendorLabel: vendorLabel,
                preferredComponentNames: preferredComponentNames,
                sourceURL: urlString
            )
        } catch {
            return .unknown(vendor: vendorLabel, reason: "status unreachable")
        }
    }

    /// Exposed for tests.
    nonisolated static func parseStatuspage(
        data: Data,
        vendorLabel: String,
        preferredComponentNames: [String],
        sourceURL: String,
        now: Date = Date()
    ) -> VendorServiceSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown(vendor: vendorLabel, reason: "status parse error")
        }

        let overall = (obj["status"] as? [String: Any])
        let indicator = (overall?["indicator"] as? String)?.lowercased() ?? "none"
        let description = (overall?["description"] as? String) ?? "Status unknown"

        var level = levelFromIndicator(indicator)

        // Elevate from preferred components if they look worse than overall "none".
        if let components = obj["components"] as? [[String: Any]] {
            let preferred = preferredComponentNames.map { $0.lowercased() }
            for c in components {
                guard let name = c["name"] as? String else { continue }
                let nl = name.lowercased()
                let isPreferred = preferred.contains(where: { nl.contains($0) || $0.contains(nl) })
                    || preferred.isEmpty
                guard isPreferred else { continue }
                let st = (c["status"] as? String)?.lowercased() ?? "operational"
                let compLevel = levelFromComponentStatus(st)
                if compLevel > level { level = compLevel }
            }
        }

        // Active incidents can force degraded even if indicator lags.
        if let incidents = obj["incidents"] as? [[String: Any]], !incidents.isEmpty {
            for inc in incidents {
                let st = (inc["status"] as? String)?.lowercased() ?? ""
                let impact = (inc["impact"] as? String)?.lowercased() ?? ""
                if st == "resolved" || st == "postmortem" || st == "completed" { continue }
                if impact == "critical" || impact == "major" {
                    level = max(level, .outage)
                } else {
                    level = max(level, .degraded)
                }
            }
        }

        let summary = "\(vendorLabel): \(description)"
        return VendorServiceSnapshot(
            level: level,
            summary: summary,
            fetchedAt: now,
            sourceURL: sourceURL
        )
    }

    nonisolated static func levelFromIndicator(_ indicator: String) -> ServiceLevel {
        switch indicator {
        case "none", "operational": return .operational
        case "minor", "maintenance": return .degraded
        case "major", "critical": return .outage
        default: return .unknown
        }
    }

    nonisolated static func levelFromComponentStatus(_ status: String) -> ServiceLevel {
        switch status {
        case "operational": return .operational
        case "degraded_performance", "partial_outage", "under_maintenance":
            return .degraded
        case "major_outage": return .outage
        default: return .unknown
        }
    }

    // MARK: - xAI (RSS — JSON statuspage blocked by Cloudflare)

    nonisolated static func fetchXAI() async -> VendorServiceSnapshot {
        guard let url = URL(string: "https://status.x.ai/feed.xml") else {
            return .unknown(vendor: "xAI")
        }
        var req = URLRequest(url: url)
        req.setValue("DashIsland/1.0 (status check)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let xml = String(data: data, encoding: .utf8)
            else {
                return .unknown(vendor: "xAI", reason: "status HTTP error")
            }
            return parseXAIRSS(xml: xml, now: Date())
        } catch {
            return .unknown(vendor: "xAI", reason: "status unreachable")
        }
    }

    /// Open incidents = items whose description lacks Status: RESOLVED (recent feed).
    nonisolated static func parseXAIRSS(xml: String, now: Date = Date()) -> VendorServiceSnapshot {
        // Split items cheaply — feed is small.
        let parts = xml.components(separatedBy: "<item>")
        var openTitles: [String] = []
        for part in parts.dropFirst() {
            let chunk = part.components(separatedBy: "</item>").first ?? part
            let lower = chunk.lowercased()
            // Resolved items tag category "resolved" or Status: RESOLVED in body.
            let resolved = lower.contains("<category>resolved</category>")
                || lower.contains("status: resolved")
                || lower.contains("<h3>status: resolved</h3>")
            if resolved { continue }
            if let title = firstXMLTag("title", in: chunk) {
                openTitles.append(title.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        if openTitles.isEmpty {
            return VendorServiceSnapshot(
                level: .operational,
                summary: "xAI: no open incidents",
                fetchedAt: now,
                sourceURL: "https://status.x.ai"
            )
        }

        let head = openTitles[0]
        let level: ServiceLevel = openTitles.count >= 3 ? .outage : .degraded
        return VendorServiceSnapshot(
            level: level,
            summary: "xAI: \(head)",
            fetchedAt: now,
            sourceURL: "https://status.x.ai"
        )
    }

    nonisolated private static func firstXMLTag(_ tag: String, in text: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let r1 = text.range(of: open),
              let r2 = text.range(of: close, range: r1.upperBound..<text.endIndex)
        else { return nil }
        return String(text[r1.upperBound..<r2.lowerBound])
    }
}

extension Notification.Name {
    static let dashIslandVendorStatusChanged = Notification.Name("dashIslandVendorStatusChanged")
}
