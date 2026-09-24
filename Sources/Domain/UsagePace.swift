import Foundation

/// "When do I run out?" from the burn ratio. With cruise = (1 − u) / timeToReset
/// and ratio = v / cruise, the time to exhaustion is timeToReset / ratio, so a
/// ratio at or below 1 lasts until the reset. Rounded to 10 minutes: the API
/// reports integer percents, so finer times would be false precision.
enum UsagePace {
    static func exhaustion(used: Double, resetAt: Date?, ratio: Double, now: Date) -> Date? {
        guard let resetAt, ratio > 1, used < 1 else { return nil }
        let toReset = resetAt.timeIntervalSince(now)
        guard toReset > 0 else { return nil }
        let seconds = (toReset / ratio / 600).rounded(.down) * 600
        return now.addingTimeInterval(seconds)
    }

    static func line(used: Double, resetAt: Date?, ratio: Double, now: Date,
                     calendar: Calendar = .current) -> String? {
        guard let resetAt, ratio > 0, used < 1, resetAt > now else { return nil }
        let reset = clock(resetAt, now: now, calendar: calendar)
        if let eta = exhaustion(used: used, resetAt: resetAt, ratio: ratio, now: now) {
            return "At this pace: out at \(clock(eta, now: now, calendar: calendar)), before the \(reset) reset"
        }
        return "At this pace: lasts until the \(reset) reset"
    }

    /// "14:00" today, "Thu 14:00" on another day. Fixed English weekday names to
    /// match the rest of the UI.
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        guard !calendar.isDate(date, inSameDayAs: now), let wd = c.weekday else { return hm }
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][wd - 1] + " " + hm
    }
}

extension WidgetViewModel {
    /// Pace for the window that drives the needle, once a burn sample exists.
    func paceLine(now: Date) -> String? {
        guard burnSampleAt != nil, let window = usageSnapshot?.preferredBurnWindow, window.isReported else { return nil }
        let ratio = burnLongRatio > 0 ? burnLongRatio : burnRatio
        guard let line = UsagePace.line(used: window.usedFraction, resetAt: window.resetAt, ratio: ratio, now: now)
        else { return nil }
        return "\(window.displayLabel) · " + line.replacingOccurrences(of: "At this pace: ", with: "")
    }
}
