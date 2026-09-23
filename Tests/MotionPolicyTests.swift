import Foundation

enum MotionPolicySuite {
    static func run() -> Int {
        print("MotionPolicy")
        var f = 0
        let live = MotionPolicy.Conditions()

        f += check("compact rim is static unless a fetch is in flight") {
            try assertTrue(MotionPolicy.rimFrameInterval(live, expanded: false, fetching: false) == nil)
            try assertTrue(MotionPolicy.rimFrameInterval(live, expanded: false, fetching: true) != nil)
        }
        f += check("expanded rim flows while visible") {
            try assertTrue(MotionPolicy.rimFrameInterval(live, expanded: true, fetching: false) != nil)
        }
        f += check("reduce motion, low power and a hidden window freeze every animation") {
            let frozen = [
                MotionPolicy.Conditions(reduceMotion: true),
                MotionPolicy.Conditions(lowPower: true),
                MotionPolicy.Conditions(hidden: true)
            ]
            for c in frozen {
                try assertTrue(!c.allowsMotion)
                try assertTrue(MotionPolicy.rimFrameInterval(c, expanded: true, fetching: true) == nil)
                try assertTrue(MotionPolicy.gaugeFrameInterval(c, burnRatio: 2) == nil)
            }
        }
        f += check("gauge at rest draws one static frame") {
            // Rest jitter moves an 80pt gauge's needle tip by less than a quarter point.
            let tipRadius = 38.0 * 80 / 96
            let travel = tipRadius * BurnMotion.needleJitterAmplitude(ratio: 0) * .pi / 180
            try assertTrue(travel < 0.25, "rest jitter \(travel)pt should be sub-pixel")
            try assertTrue(MotionPolicy.gaugeFrameInterval(live, burnRatio: 0) == nil)
            try assertTrue(MotionPolicy.gaugeFrameInterval(live, burnRatio: 0.1) == nil)
        }
        f += check("gauge breathes at 15fps below cruise energy, 30fps past it") {
            try assertEqual(MotionPolicy.gaugeFrameInterval(live, burnRatio: 0.3) ?? 0, 1.0 / 15.0, accuracy: 1e-9)
            try assertEqual(MotionPolicy.gaugeFrameInterval(live, burnRatio: 1.5) ?? 0, 1.0 / 30.0, accuracy: 1e-9)
        }
        return f
    }
}
