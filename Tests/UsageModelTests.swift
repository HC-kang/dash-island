import Foundation

/// Persisted usage types and error classification.
enum UsageModelSuite {
    static func run() -> Int {
        print("UsageModel")
        var failures = 0

        failures += check("last-good snapshot saved before a defaulted field still decodes") {
            let snapshot = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.4, kind: .fiveHour),
                secondary: WindowUsage(usedFraction: 0.1, kind: .weekly),
                extras: [WindowUsage(usedFraction: 0.2, labelOverride: "Fable")],
                plan: "max",
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let encoder = JSONEncoder()
            var object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as! [String: Any]
            object.removeValue(forKey: "extras")
            let old = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: old)
            try assertEqual(decoded.extras, [])
            try assertEqual(decoded.primary, snapshot.primary)
            try assertEqual(decoded.plan, "max")
            // Full round trip is unchanged.
            try assertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: encoder.encode(snapshot)), snapshot)
        }

        return failures
    }
}
