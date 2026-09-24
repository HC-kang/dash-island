import Foundation

enum StatusExportSuite {
    static func run() -> Int {
        print("StatusExport")
        var f = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3_600)
        let row = StatusExport.Account(
            id: "ABCDEF12", label: "work", vendor: "claude", health: "ok",
            windows: [.init(label: "5h", usedPercent: 42, resetAt: reset)],
            lastSuccessAt: now, stale: false)
        f += check("export is versioned JSON with ISO dates") {
            let data = try StatusExport.encode(StatusExport(generatedAt: now, accounts: [row]))
            let text = String(decoding: data, as: UTF8.self)
            try assertTrue(text.contains("\"version\":1"), text)
            try assertTrue(text.contains("\"usedPercent\":42"), text)
            try assertTrue(text.contains("\"resetAt\":\"2027-01-15T09:00:00Z\""), text)
        }
        f += check("export carries only allowlisted keys") {
            let data = try StatusExport.encode(StatusExport(generatedAt: now, accounts: [row]))
            let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try assertEqual(Set(root.keys), ["version", "generatedAt", "accounts"])
            let account = (root["accounts"] as! [[String: Any]])[0]
            try assertEqual(Set(account.keys), ["id", "label", "vendor", "health", "windows", "lastSuccessAt", "stale"])
        }
        return f
    }
}
