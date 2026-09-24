import Foundation

enum CollectorUpdaterSuite {
    static func run() -> Int {
        print("CollectorUpdater")
        var f = 0
        f += check("interpreter comes from the installed LaunchAgent") {
            let plist: [String: Any] = ["Label": "dev.dashisland.usage-collector",
                                        "ProgramArguments": ["/opt/py/bin/python3", "/x/usage-collector.py"]]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try assertEqual(CollectorUpdater.interpreter(fromLaunchAgent: data), "/opt/py/bin/python3")
            try assertEqual(CollectorUpdater.interpreter(fromLaunchAgent: Data("junk".utf8)), nil)
        }
        f += check("only an out-of-date collector triggers an automatic update") {
            try assertEqual(CollectorUpdater.shouldAutoUpdate(.outdated), true)
            try assertEqual(CollectorUpdater.shouldAutoUpdate(.notConnected), false)  // needs the user's consent
            try assertEqual(CollectorUpdater.shouldAutoUpdate(.active), false)
        }
        return f
    }
}
