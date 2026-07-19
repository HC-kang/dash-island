import Foundation

// Simple assert-style suite compiled with Domain sources via scripts/run-tests.sh.
// No XCTest dependency — keeps the tree free of an Xcode project.

@main
struct BurnRateTests {
    static func main() {
        var failures = 0

        failures += run("ratio is 0 when only one sample / no prev") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let burn = BurnRate.compute(
                prev: nil,
                current: (usedFraction: 0.40, at: now),
                resetAt: now.addingTimeInterval(5 * 3600)
            )
            try assertEqual(burn.ratio, 0, accuracy: 1e-9)
            try assertEqual(Double(burn.sampleCount), 1, accuracy: 0)
        }

        failures += run("ratio is 1 when Δ matches cruise-to-reset") {
            // ratio = 1 when v == v_cruise:
            //   (u1 − u0) / dt == (1 − u1) / timeToReset
            // Pick u0=0.20, dt=1h, timeToReset=4h → u1=0.36
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let dt: TimeInterval = 3600
            let timeToReset: TimeInterval = 4 * 3600
            let t1 = t0.addingTimeInterval(dt)
            let resetAt = t1.addingTimeInterval(timeToReset)
            let u0 = 0.20
            // (u1 - u0) * timeToReset = (1 - u1) * dt
            // u1 * (timeToReset + dt) = u0 * timeToReset + dt
            let u1 = (u0 * timeToReset + dt) / (timeToReset + dt)

            let burn = BurnRate.compute(
                prev: (usedFraction: u0, at: t0),
                current: (usedFraction: u1, at: t1),
                resetAt: resetAt
            )
            try assertEqual(burn.ratio, 1.0, accuracy: 1e-9)
            try assertEqual(Double(burn.sampleCount), 2, accuracy: 0)
        }

        failures += run("needleUnit: 0 → rest, 1 → cruise, ≥2 soft-cap redline") {
            try assertEqual(BurnRate.needleUnit(ratio: 0), 0.0, accuracy: 1e-12)
            try assertEqual(BurnRate.needleUnit(ratio: 1), 0.5, accuracy: 1e-12) // cruise mid-arc
            try assertEqual(BurnRate.needleUnit(ratio: 2), 1.0, accuracy: 1e-12)
            try assertEqual(BurnRate.needleUnit(ratio: 3), 1.0, accuracy: 1e-12) // soft-cap
            try assertEqual(BurnRate.needleUnit(ratio: -1), 0.0, accuracy: 1e-12)
        }

        failures += run("negative usage delta yields ratio 0") {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let t1 = t0.addingTimeInterval(3600)
            let burn = BurnRate.compute(
                prev: (usedFraction: 0.50, at: t0),
                current: (usedFraction: 0.40, at: t1),
                resetAt: t1.addingTimeInterval(4 * 3600)
            )
            try assertEqual(burn.ratio, 0, accuracy: 1e-9)
        }

        if failures == 0 {
            print("✓ All BurnRate tests passed")
            exit(0)
        } else {
            print("✗ \(failures) test(s) failed")
            exit(1)
        }
    }
}

// MARK: - Mini test helpers

@discardableResult
private func run(_ name: String, body: () throws -> Void) -> Int {
    do {
        try body()
        print("  ✓ \(name)")
        return 0
    } catch {
        print("  ✗ \(name): \(error)")
        return 1
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func assertEqual(_ actual: Double, _ expected: Double, accuracy: Double) throws {
    if abs(actual - expected) > accuracy {
        throw TestFailure(description: "expected \(expected), got \(actual) (accuracy \(accuracy))")
    }
}
