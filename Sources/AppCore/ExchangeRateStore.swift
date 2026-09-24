import Foundation

/// USD→KRW rate for the KRW display option, cached for a day in UserDefaults.
/// Fetched only while KRW is selected, so USD users make no extra request.
@MainActor
final class ExchangeRateStore: ObservableObject {
    static let shared = ExchangeRateStore()
    private static let rateKey = "DashIsland.krwPerUSD"
    private static let dateKey = "DashIsland.krwPerUSDAt"
    private static let url = URL(string: "https://open.er-api.com/v6/latest/USD")!

    private let defaults: UserDefaults
    @Published private(set) var krwPerUSD: Double?
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let cached = defaults.double(forKey: Self.rateKey)
        krwPerUSD = cached > 0 ? cached : nil
    }

    func refreshIfNeeded(now: Date = Date()) {
        let fetchedAt = defaults.object(forKey: Self.dateKey) as? Date
        guard task == nil, krwPerUSD == nil || fetchedAt.map({ now.timeIntervalSince($0) > 86_400 }) ?? true else { return }
        task = Task { [weak self] in
            defer { self?.task = nil }
            var request = URLRequest(url: Self.url)
            request.timeoutInterval = 15
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let rate = CurrencyDisplay.parseKRWRate(data)
            else {
                Log.app.warn("exchange rate fetch failed; keeping \(self?.krwPerUSD == nil ? "USD" : "cached rate")")
                return
            }
            self?.krwPerUSD = rate
            self?.defaults.set(rate, forKey: Self.rateKey)
            self?.defaults.set(now, forKey: Self.dateKey)
            Log.app.info("exchange rate updated krwPerUSD=\(Int(rate))")
        }
    }
}
