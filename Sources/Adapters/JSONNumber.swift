import Foundation

/// Vendor JSON numbers without traps. `Int64(1e20)` or an `"inf"` string used
/// to crash the whole app on one odd response.
enum JSONNumber {
    /// Finite number from a JSON number or numeric string, else `nil`.
    static func double(_ value: Any?) -> Double? {
        let d: Double?
        if let v = value as? Double { d = v }
        else if let v = value as? Int { d = Double(v) }
        else if let v = value as? Int64 { d = Double(v) }
        else if let v = value as? NSNumber { d = v.doubleValue }
        else if let s = value as? String { d = Double(s.trimmingCharacters(in: .whitespaces)) }
        else { d = nil }
        guard let d, d.isFinite else { return nil }
        return d
    }

    /// Non-negative counter, rounded; `nil` when absent or outside `Int64`.
    static func int64(_ value: Any?) -> Int64? {
        if let i = value as? Int64 { return max(0, i) }
        if let i = value as? Int { return max(0, Int64(i)) }
        guard let d = double(value) else { return nil }
        return int64(d)
    }

    static func int64(_ value: Double) -> Int64? {
        Int64(exactly: value.rounded()).map { max(0, $0) }
    }
}
