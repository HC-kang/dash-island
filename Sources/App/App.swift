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
        let env = ProcessInfo.processInfo.environment
        Log.level = Log.resolveLevel(env: env, defaults: .standard)
        Log.startFile(at: Log.defaultFileURL)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.app.info(
            "launch version=\(version) pid=\(ProcessInfo.processInfo.processIdentifier) level=\(Log.level) demo=\(env["DASHISLAND_DEMO"] == "1") support=\(CredentialStore.appSupportURL.path) file=\(Log.fileURL?.path ?? "off")"
        )
        AccountStore.shared.load()
        UsageOrchestrator.shared.startAutoRefresh()
        AlertCenter.shared.start()
        StatusFile.shared.start()
        island = IslandWindowController()
        island?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
