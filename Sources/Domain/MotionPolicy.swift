import Foundation

/// Frame-rate policy for island decoration (rim sweep, gauge breath).
///
/// `nil` means paused: draw one static frame. The island sits on screen all day,
/// so motion must earn its frames — nobody watches a compact rim between polls.
enum MotionPolicy {
    struct Conditions: Equatable {
        /// System Reduce Motion setting.
        var reduceMotion = false
        /// Low Power Mode.
        var lowPower = false
        /// Window occluded or displays asleep: no frame can be seen.
        var hidden = false

        var allowsMotion: Bool { !reduceMotion && !lowPower && !hidden }
    }

    static let rimInterval: TimeInterval = 1.0 / 30.0
    /// Below this burn energy the needle jitter is sub-pixel (see tests).
    static let restEnergy = 0.05

    /// Compact rim flows only while a fetch is in flight; expanded rim flows while shown.
    static func rimFrameInterval(_ c: Conditions, expanded: Bool, fetching: Bool) -> TimeInterval? {
        guard c.allowsMotion, expanded || fetching else { return nil }
        return rimInterval
    }

    /// Gauge breath / needle jitter: static at rest, 15fps below cruise, 30fps past it.
    static func gaugeFrameInterval(_ c: Conditions, burnRatio: Double) -> TimeInterval? {
        guard c.allowsMotion else { return nil }
        let e = BurnMotion.energy(ratio: burnRatio)
        guard e >= restEnergy else { return nil }
        return e < 0.35 ? 1.0 / 15.0 : 1.0 / 30.0
    }
}
