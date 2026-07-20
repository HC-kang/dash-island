import Combine
import Foundation
import ServiceManagement

/// macOS 13+ login item via `SMAppService.mainApp`.
@MainActor
final class LaunchAtLoginStore: ObservableObject {
    static let shared = LaunchAtLoginStore()

    @Published private(set) var isEnabled: Bool

    init() {
        self.isEnabled = Self.readEnabled()
    }

    func refresh() {
        isEnabled = Self.readEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = Self.readEnabled()
        } catch {
            NSLog("DashIsland: Launch at Login failed: %@", error.localizedDescription)
            isEnabled = Self.readEnabled()
        }
    }

    private static func readEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}
