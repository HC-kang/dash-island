import Foundation

enum AccountsPersistenceSuite {
    static func run() -> Int {
        print("AccountsPersistence")
        var failures = 0

        failures += check("round-trip save/load preserves accounts") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let fileURL = dir.appendingPathComponent("accounts.json")
            let persistence = AccountsPersistence(fileURL: fileURL)

            let id1 = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
            let id2 = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let auth = Date(timeIntervalSince1970: 1_700_000_100)

            let original: [Account] = [
                Account(
                    id: id1,
                    vendorID: "fake",
                    label: "Fake A",
                    credentialRef: id1.uuidString,
                    sortIndex: 0,
                    createdAt: created,
                    lastAuthenticatedAt: auth
                ),
                Account(
                    id: id2,
                    vendorID: "fake",
                    label: "Fake B",
                    credentialRef: id2.uuidString,
                    sortIndex: 1,
                    createdAt: created,
                    lastAuthenticatedAt: nil
                ),
            ]

            try persistence.save(original)
            let loaded = try persistence.load()

            try assertEqual(loaded.count, 2)
            try assertEqual(loaded[0].id, id1)
            try assertEqual(loaded[0].vendorID, "fake")
            try assertEqual(loaded[0].label, "Fake A")
            try assertEqual(loaded[0].credentialRef, id1.uuidString)
            try assertEqual(loaded[0].sortIndex, 0)
            try assertEqual(loaded[0].createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.5)
            try assertEqual(loaded[0].lastAuthenticatedAt!.timeIntervalSince1970, auth.timeIntervalSince1970, accuracy: 0.5)
            try assertEqual(loaded[1].id, id2)
            try assertEqual(loaded[1].lastAuthenticatedAt == nil, true)
        }

        failures += check("missing file loads as empty list") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let persistence = AccountsPersistence(
                fileURL: dir.appendingPathComponent("accounts.json")
            )
            let loaded = try persistence.load()
            try assertEqual(loaded.count, 0)
        }

        failures += check("AccountStore rejects add beyond max 5") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let persistence = AccountsPersistence(
                fileURL: dir.appendingPathComponent("accounts.json")
            )

            // AccountStore is @MainActor — hop explicitly.
            try runOnMain {
                let store = AccountStore(persistence: persistence)
                store.load()
                for i in 0..<AccountStore.maxAccounts {
                    let id = UUID()
                    try store.add(
                        Account(
                            id: id,
                            vendorID: "fake",
                            label: "A\(i)",
                            credentialRef: id.uuidString,
                            sortIndex: i,
                            createdAt: Date(),
                            lastAuthenticatedAt: nil
                        )
                    )
                }
                try assertEqual(store.accounts.count, AccountStore.maxAccounts)

                let extra = UUID()
                try assertThrows(AccountStoreError.maxAccountsReached) {
                    try store.add(
                        Account(
                            id: extra,
                            vendorID: "fake",
                            label: "overflow",
                            credentialRef: extra.uuidString,
                            sortIndex: 99,
                            createdAt: Date(),
                            lastAuthenticatedAt: nil
                        )
                    )
                }
                try assertEqual(store.accounts.count, AccountStore.maxAccounts)
            }
        }

        failures += check("AccountStore load after save restores list") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let fileURL = dir.appendingPathComponent("accounts.json")
            let persistence = AccountsPersistence(fileURL: fileURL)

            let id = UUID()
            try runOnMain {
                let store = AccountStore(persistence: persistence)
                try store.add(
                    Account(
                        id: id,
                        vendorID: "fake",
                        label: "Persisted",
                        credentialRef: id.uuidString,
                        sortIndex: 0,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        lastAuthenticatedAt: nil
                    )
                )
            }

            try runOnMain {
                let reloaded = AccountStore(persistence: persistence)
                reloaded.load()
                try assertEqual(reloaded.accounts.count, 1)
                try assertEqual(reloaded.accounts[0].id, id)
                try assertEqual(reloaded.accounts[0].label, "Persisted")
            }
        }

        failures += check("FakeAdapter fraction is deterministic for a ref") {
            let ref = "DEADBEEF-0000-0000-0000-000000000001"
            let a = FakeAdapter.fraction(from: ref)
            let b = FakeAdapter.fraction(from: ref)
            try assertEqual(a, b, accuracy: 0)
            try assertTrue(a >= 0 && a < 1, "fraction in 0..<1, got \(a)")
            let other = FakeAdapter.fraction(from: "other-ref")
            try assertTrue(other >= 0 && other < 1, "fraction in 0..<1, got \(other)")
        }

        return failures
    }

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func runOnMain(_ body: @escaping @MainActor () throws -> Void) throws {
        // AccountStore is @MainActor. Schedule work, then spin the run loop until done
        // (a plain semaphore would deadlock — MainActor needs the run loop).
        nonisolated(unsafe) var caught: Error?
        nonisolated(unsafe) var done = false
        Task { @MainActor in
            do {
                try body()
            } catch {
                caught = error
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done {
            if Date() > deadline {
                throw TestFailure(description: "timed out waiting for MainActor work")
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        if let caught { throw caught }
    }
}
