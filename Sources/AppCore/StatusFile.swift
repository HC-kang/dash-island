import Combine
import Foundation

/// Keeps `~/Library/Application Support/DashIsland/status.json` in step with the
/// widgets (debounced), atomically and owner-only. See `StatusExport`.
@MainActor
final class StatusFile {
    static let shared = StatusFile()
    static var url: URL { CredentialStore.appSupportURL.appendingPathComponent("status.json") }
    private var cancellable: AnyCancellable?

    func start() {
        cancellable = UsageOrchestrator.shared.$widgets
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { widgets in
                guard !widgets.isEmpty,
                      let data = try? StatusExport.encode(StatusExport.make(widgets: widgets, now: Date()))
                else { return }
                do {
                    try data.write(to: Self.url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
                } catch {
                    Log.app.warn("status.json write failed error=\(error.localizedDescription)")
                }
            }
    }
}
