import Combine
import Foundation
import UserNotifications

/// Watches widget updates and posts macOS notifications for threshold crossings,
/// window resets after a warning, and accounts that need sign-in. Policy lives in
/// `AlertEngine` (pure); this type only remembers state and delivers.
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()

    private static let memoryKey = "DashIsland.alertMemory"
    private let defaults: UserDefaults
    private var memory: [String: AlertMemory]
    private var cancellable: AnyCancellable?
    private var authorized: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        memory = (defaults.data(forKey: Self.memoryKey))
            .flatMap { try? JSONDecoder().decode([String: AlertMemory].self, from: $0) } ?? [:]
    }

    func start() {
        cancellable = UsageOrchestrator.shared.$widgets
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in self?.evaluate($0) }
    }

    func evaluate(_ widgets: [WidgetViewModel]) {
        var alerts: [(AccountID, UsageAlert)] = []
        var live = Set<String>()
        for w in widgets where !w.isAwaitingFirstSample {
            let authKey = "\(w.id.uuidString)|auth"
            live.insert(authKey)
            let (signIn, signInMemory) = AlertEngine.signIn(account: w.title, needsSignIn: w.health == .error,
                                                            memory: memory[authKey])
            memory[authKey] = signInMemory
            if let signIn { alerts.append((w.id, signIn)) }

            guard let s = w.usageSnapshot, s.error == nil else { continue }
            for window in ([s.primary] + [s.secondary, s.tertiary].compactMap { $0 } + s.extras) where window.isReported {
                let key = "\(w.id.uuidString)|\(window.displayLabel)"
                live.insert(key)
                let (alert, next) = AlertEngine.usage(account: w.title, window: window.displayLabel,
                                                      used: window.usedFraction, resetAt: window.resetAt,
                                                      memory: memory[key])
                memory[key] = next
                if let alert { alerts.append((w.id, alert)) }
            }
        }
        // Removed accounts and vanished windows drop out, so the memory stays bounded.
        memory = memory.filter { live.contains($0.key) }
        if let data = try? JSONEncoder().encode(memory) { defaults.set(data, forKey: Self.memoryKey) }
        guard !alerts.isEmpty else { return }
        // Labels can be e-mail addresses: log the kind and the short id only.
        for (id, alert) in alerts { Log.poll.info("alert kind=\(alert.kind) account=\(id.short)") }
        guard PreferencesStore.shared.alertNotifications else { return }
        deliver(alerts.map(\.1))
    }

    private func deliver(_ alerts: [UsageAlert]) {
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                Log.app.info("notifications authorized=\(authorized ?? false)")
            }
            guard authorized == true else { return }
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                if case .crossed(_, _, _, true) = alert { content.sound = .default }
                if case .signIn = alert { content.sound = .default }
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                do { try await center.add(request) } catch {
                    Log.app.warn("notification failed error=\(error.localizedDescription)")
                }
            }
        }
    }
}
