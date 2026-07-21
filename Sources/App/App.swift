import AppKit
import SwiftUI

@main
struct DashIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var island: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Credentials live outside the bundle — log the path every launch.
        NSLog(
            "DashIsland: Application Support → %@",
            CredentialStore.appSupportURL.path
        )
        if ProcessInfo.processInfo.environment["DASHISLAND_DEMO"] == "1" {
            NSLog("DashIsland: DASHISLAND_DEMO=1 — UI shows fake widgets; real accounts on disk are untouched")
        }
        AccountStore.shared.load()
        UsageOrchestrator.shared.startAutoRefresh()
        island = IslandWindowController()
        island?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
