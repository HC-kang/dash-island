import Foundation

enum CredentialStoreSuite {
    static func run() -> Int {
        print("CredentialStoreSuite")
        var failures = 0
        let fm = FileManager.default

        failures += check("credential ref must be one folder name") {
            try assertTrue(CredentialStore.isValidRef(UUID().uuidString))
            for bad in ["", ".", "..", "a/b", "../x", "/"] {
                try assertTrue(!CredentialStore.isValidRef(bad), "ref \(bad.debugDescription) must be rejected")
            }
        }

        failures += check("remove with an empty or dot ref never deletes the accounts root") {
            let base = try makeTempDir()
            defer { try? fm.removeItem(at: base) }
            let root = base.appendingPathComponent("accounts", isDirectory: true)
            let keep = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: keep, withIntermediateDirectories: true)
            for bad in ["", ".", ".."] {
                try assertThrows(CredentialStoreError.invalidRef) {
                    try CredentialStore.removeDirectory(for: bad, root: root)
                }
            }
            try assertTrue(fm.fileExists(atPath: keep.path), "sibling account survives")
            try assertTrue(fm.fileExists(atPath: base.path), "parent survives")
            try CredentialStore.removeDirectory(for: keep.lastPathComponent, root: root)
            try assertTrue(!fm.fileExists(atPath: keep.path))
        }

        failures += check("account folders are owner-only (0700), including old 0755 ones") {
            let root = try makeTempDir()
            defer { try? fm.removeItem(at: root) }
            let fresh = try CredentialStore.createDirectory(for: UUID().uuidString, root: root)
            try assertEqual(try mode(fresh), 0o700)
            let old = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: old, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            _ = try CredentialStore.createDirectory(for: old.lastPathComponent, root: root)
            try assertEqual(try mode(old), 0o700)
            try assertThrows(CredentialStoreError.invalidRef) {
                _ = try CredentialStore.createDirectory(for: "", root: root)
            }
        }

        failures += check("writeSecret creates 0600 files and reports a failed write") {
            let dir = try makeTempDir()
            defer {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                try? fm.removeItem(at: dir)
            }
            let file = dir.appendingPathComponent("auth.json")
            try CredentialStore.writeSecret(Data("{\"a\":1}".utf8), to: file)
            try assertEqual(try mode(file), 0o600)
            try assertEqual(try Data(contentsOf: file), Data("{\"a\":1}".utf8))
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            var threw = false
            do {
                try CredentialStore.writeSecret(Data("x".utf8), to: dir.appendingPathComponent("new.json"))
            } catch {
                threw = true
            }
            try assertTrue(threw, "write into a read-only folder must throw, not pass silently")
        }

        failures += check("prior files: restore brings the old session back and drops the new one") {
            let dir = try makeTempDir()
            defer { try? fm.removeItem(at: dir) }
            let live = dir.appendingPathComponent("auth.json")
            let nested = dir.appendingPathComponent(".codex/auth.json")
            try Data("old".utf8).write(to: live)
            let prior = CredentialStore.PriorFiles.stash([live, nested])
            try assertTrue(!fm.fileExists(atPath: live.path), "CLI must see no session while logging in")
            try fm.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("rejected".utf8).write(to: nested)
            try Data("rejected".utf8).write(to: live)
            prior.restore()
            try assertEqual(try Data(contentsOf: live), Data("old".utf8))
            try assertTrue(!fm.fileExists(atPath: nested.path), "new session at another path is dropped too")
            try assertTrue(!fm.fileExists(atPath: CredentialStore.PriorFiles.priorURL(for: live).path))
        }

        failures += check("prior files: discard keeps the new session and removes the copy") {
            let dir = try makeTempDir()
            defer { try? fm.removeItem(at: dir) }
            let live = dir.appendingPathComponent("auth.json")
            try Data("old".utf8).write(to: live)
            let prior = CredentialStore.PriorFiles.stash([live])
            try Data("new".utf8).write(to: live)
            prior.discard()
            try assertEqual(try Data(contentsOf: live), Data("new".utf8))
            try assertTrue(!fm.fileExists(atPath: CredentialStore.PriorFiles.priorURL(for: live).path))
        }

        failures += check("prior files: a copy left by a crashed reauth is restored, not lost") {
            let dir = try makeTempDir()
            defer { try? fm.removeItem(at: dir) }
            let live = dir.appendingPathComponent("auth.json")
            try Data("old".utf8).write(to: CredentialStore.PriorFiles.priorURL(for: live))
            let prior = CredentialStore.PriorFiles.stash([live])
            prior.restore()
            try assertEqual(try Data(contentsOf: live), Data("old".utf8))
        }

        failures += check("tightenPermissions makes the root and existing account folders 0700") {
            let root = fm.temporaryDirectory.appendingPathComponent("tighten-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            for name in ["", "a", "b"] {
                let dir = name.isEmpty ? root : root.appendingPathComponent(name)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            }
            try Data("x".utf8).write(to: root.appendingPathComponent("a/file"))
            try assertEqual(CredentialStore.tightenPermissions(root: root), 3)
            for name in ["", "a", "b"] {
                let path = (name.isEmpty ? root : root.appendingPathComponent(name)).path
                let mode = (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
                try assertEqual(mode, 0o700)
            }
            try assertEqual(CredentialStore.tightenPermissions(root: root), 0)  // idempotent
        }

        failures += check("recoverPriorFiles restores a lone .prior and drops a stale one") {
            let root = fm.temporaryDirectory.appendingPathComponent("prior-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            try fm.createDirectory(at: a, withIntermediateDirectories: true)
            try fm.createDirectory(at: b, withIntermediateDirectories: true)
            // a: crash mid-reauth left only the stash.
            try Data("old-a".utf8).write(to: a.appendingPathComponent("auth.json.prior"))
            // b: the new login landed before the crash; the stash is stale.
            try Data("new-b".utf8).write(to: b.appendingPathComponent("auth.json"))
            try Data("old-b".utf8).write(to: b.appendingPathComponent("auth.json.prior"))
            try assertEqual(CredentialStore.recoverPriorFiles(root: root), 2)
            try assertEqual(String(decoding: try Data(contentsOf: a.appendingPathComponent("auth.json")), as: UTF8.self), "old-a")
            try assertEqual(String(decoding: try Data(contentsOf: b.appendingPathComponent("auth.json")), as: UTF8.self), "new-b")
            try assertEqual(fm.fileExists(atPath: a.appendingPathComponent("auth.json.prior").path), false)
            try assertEqual(fm.fileExists(atPath: b.appendingPathComponent("auth.json.prior").path), false)
            try assertEqual(CredentialStore.recoverPriorFiles(root: root), 0)
        }

        return failures
    }

    private static func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-creds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
