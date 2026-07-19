import Foundation

/// Single entry point for all suites (compiled via `scripts/run-tests.sh`).
@main
struct TestMain {
    static func main() {
        var failures = 0
        failures += BurnRateSuite.run()
        failures += AccountsPersistenceSuite.run()
        failures += OrchestratorDueSuite.run()
        failures += ClaudeAdapterSuite.run()

        if failures == 0 {
            print("✓ All tests passed")
            exit(0)
        } else {
            print("✗ \(failures) test(s) failed")
            exit(1)
        }
    }
}

// MARK: - Mini test helpers (shared)

@discardableResult
func check(_ name: String, body: () throws -> Void) -> Int {
    do {
        try body()
        print("  ✓ \(name)")
        return 0
    } catch {
        print("  ✗ \(name): \(error)")
        return 1
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func assertEqual(_ actual: Double, _ expected: Double, accuracy: Double) throws {
    if abs(actual - expected) > accuracy {
        throw TestFailure(description: "expected \(expected), got \(actual) (accuracy \(accuracy))")
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
    if actual != expected {
        throw TestFailure(description: "expected \(expected), got \(actual)")
    }
}

func assertTrue(_ value: Bool, _ message: String = "expected true") throws {
    if !value {
        throw TestFailure(description: message)
    }
}

func assertThrows<E: Error & Equatable>(
    _ expected: E,
    body: () throws -> Void
) throws {
    do {
        try body()
        throw TestFailure(description: "expected throw \(expected), got success")
    } catch let error as E {
        if error != expected {
            throw TestFailure(description: "expected throw \(expected), got \(error)")
        }
    } catch let error as TestFailure {
        throw error
    } catch {
        throw TestFailure(description: "expected throw \(expected), got \(error)")
    }
}
