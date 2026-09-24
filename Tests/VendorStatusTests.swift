import Foundation

enum VendorStatusSuite {
    static func run() -> Int {
        print("VendorStatus")
        var failures = 0

        // Shape of status.openai.com/api/v2/summary.json (names as of 2026-09-23).
        func openAI(indicator: String, components: String, incidents: String = "[]") -> VendorServiceSnapshot {
            let json = """
            {
              "status": { "indicator": "\(indicator)", "description": "Partial System Outage" },
              "components": \(components),
              "incidents": \(incidents)
            }
            """
            return VendorStatusStore.parseStatuspage(
                data: Data(json.utf8),
                vendorLabel: "OpenAI",
                preferredComponentNames: VendorStatusStore.openAIComponents,
                sourceURL: "https://status.openai.com"
            )
        }
        let quietCodex = """
        [
          { "id": "sora", "name": "Sora", "status": "major_outage" },
          { "id": "ads", "name": "Ads API", "status": "partial_outage" },
          { "id": "compliance", "name": "Compliance API", "status": "major_outage" },
          { "id": "atlas", "name": "ChatGPT Atlas", "status": "degraded_performance" },
          { "id": "codex-api", "name": "Codex API", "status": "operational" },
          { "id": "cli", "name": "CLI", "status": "operational" }
        ]
        """

        failures += check("unrelated OpenAI components and incidents do not mark Codex") {
            let incidents = """
            [{ "name": "Sora video generation down", "status": "investigating", "impact": "critical",
               "components": [{ "id": "sora", "name": "Sora" }] }]
            """
            let snap = openAI(indicator: "major", components: quietCodex, incidents: incidents)
            try assertEqual(snap.level, ServiceLevel.operational)
            // A green dot must not carry a page-wide outage headline as if it were ours.
            try assertTrue(!snap.summary.contains("Sora"), "got \(snap.summary)")
            let health = AccountHealth.resolve(error: nil, notice: nil, awaitingFirst: false, service: snap)
            try assertEqual(health.health, AccountHealth.ok)
        }

        failures += check("an incident on a Codex component marks Codex") {
            let incidents = """
            [{ "name": "Elevated CLI errors", "status": "identified", "impact": "minor",
               "components": [{ "id": "cli", "name": "CLI" }] }]
            """
            let snap = openAI(indicator: "minor", components: quietCodex, incidents: incidents)
            try assertEqual(snap.level, ServiceLevel.degraded)
            try assertTrue(snap.summary.contains("Elevated CLI errors"), "got \(snap.summary)")
        }

        failures += check("a Codex component outage marks Codex without an incident") {
            let components = quietCodex.replacingOccurrences(
                of: #""name": "Codex API", "status": "operational""#,
                with: #""name": "Codex API", "status": "major_outage""#
            )
            let snap = openAI(indicator: "major", components: components)
            try assertEqual(snap.level, ServiceLevel.outage)
            try assertTrue(snap.summary.contains("Codex API"), "got \(snap.summary)")
        }

        failures += check("names are matched exactly, not as substrings") {
            let names = VendorStatusStore.openAIComponents.map { $0.lowercased() }
            for unrelated in ["Ads API", "Compliance API", "ChatGPT Atlas", "Sora"] {
                try assertTrue(!names.contains(unrelated.lowercased()), "\(unrelated) must not match")
            }
            for codex in ["Codex API", "Codex Web", "CLI"] {
                try assertTrue(names.contains(codex.lowercased()), "\(codex) must match")
            }
        }

        failures += check("page without any named component falls back to the page indicator") {
            let components = #"[{ "id": "x", "name": "Something Renamed", "status": "operational" }]"#
            let snap = openAI(indicator: "minor", components: components)
            try assertEqual(snap.level, ServiceLevel.degraded)
        }

        return failures
    }
}
