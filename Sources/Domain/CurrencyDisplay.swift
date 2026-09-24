import Foundation

/// Display currency for API-equivalent cost. Prices and math stay in USD; KRW is
/// a display conversion (whole won, marked "≈"), and falls back to USD without a rate.
enum CurrencyDisplay {
    enum Currency: String, CaseIterable, Sendable { case usd, krw }

    static func format(usd: Double, currency: Currency, krwPerUSD: Double?) -> String {
        if currency == .krw, let rate = krwPerUSD, rate > 0 {
            let won = (usd * rate).rounded()
            return "≈₩" + won.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
        }
        return usd.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
    }

    /// `open.er-api.com/v6/latest/USD` → `rates.KRW`, only when sane.
    static func parseKRWRate(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["result"] as? String == "success",
              let rate = (root["rates"] as? [String: Any])?["KRW"] as? Double,
              rate > 100, rate < 10_000
        else { return nil }
        return rate
    }
}
