import Foundation

enum CurrencyDisplaySuite {
    static func run() -> Int {
        print("CurrencyDisplay")
        var f = 0
        f += check("USD keeps two decimals") {
            try assertEqual(CurrencyDisplay.format(usd: 367.984, currency: .usd, krwPerUSD: 1364.77), "$367.98")
        }
        f += check("KRW converts to whole won with an approximate sign") {
            try assertEqual(CurrencyDisplay.format(usd: 367.98, currency: .krw, krwPerUSD: 1364.77), "≈₩502,208")
        }
        f += check("KRW without a rate falls back to USD") {
            try assertEqual(CurrencyDisplay.format(usd: 12.5, currency: .krw, krwPerUSD: nil), "$12.50")
        }
        f += check("rate parser reads rates.KRW and rejects nonsense") {
            let ok = Data(#"{"result":"success","rates":{"KRW":1364.768247,"USD":1}}"#.utf8)
            try assertEqual(CurrencyDisplay.parseKRWRate(ok), 1364.768247)
            try assertEqual(CurrencyDisplay.parseKRWRate(Data(#"{"result":"error"}"#.utf8)), nil)
            try assertEqual(CurrencyDisplay.parseKRWRate(Data(#"{"result":"success","rates":{"KRW":-3}}"#.utf8)), nil)
        }
        return f
    }
}
