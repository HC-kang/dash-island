import Foundation

/// Keeps the local usage collector current without asking the user: an installed
/// but older copy is replaced by the one bundled with this build
/// (`connect-usage.py --update`, which changes no CLI config). Connecting for the
/// first time edits CLI configs, so that still waits for the user's click.
@MainActor
final class CollectorUpdater: ObservableObject {
    static let shared = CollectorUpdater()
    private static let label = "dev.dashisland.usage-collector"

    enum Status: Equatable { case idle, running, failed(String) }
    @Published private(set) var status: Status = .idle

    nonisolated static func interpreter(fromLaunchAgent data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String], let first = args.first, !first.isEmpty
        else { return nil }
        return first
    }

    nonisolated static func shouldAutoUpdate(_ state: CollectorHealth.State) -> Bool { state == .outdated }

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Python that already runs the collector (checked >= 3.11 at connect), else PATH.
    private static func pythonCommand() -> [String] {
        if let data = try? Data(contentsOf: launchAgentURL), let path = interpreter(fromLaunchAgent: data),
           FileManager.default.isExecutableFile(atPath: path) {
            return [path]
        }
        return ["/usr/bin/env", "python3"]
    }

    func updateIfOutdated() {
        guard status != .running,
              Self.shouldAutoUpdate(AccountUsageReader.collectorHealth().state) else { return }
        run(arguments: ["--update"], what: "update")
    }

    /// First connection: edits CLI configs, so only from an explicit click.
    func connect() {
        guard status != .running else { return }
        run(arguments: [], what: "connect")
    }

    private func run(arguments: [String], what: String) {
        guard let script = Bundle.main.url(forResource: "connect-usage", withExtension: "py") else {
            status = .failed(String(localized: "The connector script is missing from the app bundle."))
            return
        }
        status = .running
        let command = Self.pythonCommand() + [script.path] + arguments
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            var code: Int32 = -1
            var text = ""
            do {
                try process.run()
                let finished = await LoginProcess.waitForExit(process, timeout: 60)
                text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                code = finished ? process.terminationStatus : -1
            } catch {
                text = error.localizedDescription
            }
            let lastLine = text.split(separator: "\n").last.map(String.init) ?? ""
            let exitCode = code
            await MainActor.run {
                if exitCode == 0 {
                    Log.local.info("collector \(what) outcome=ok")
                    CollectorUpdater.shared.status = .idle
                } else {
                    Log.local.warn("collector \(what) outcome=failed code=\(exitCode)")
                    CollectorUpdater.shared.status = .failed(lastLine.isEmpty ? String(localized: "The collector could not be updated.") : lastLine)
                }
            }
        }
    }
}
