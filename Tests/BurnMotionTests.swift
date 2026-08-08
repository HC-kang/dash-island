import Foundation

enum BurnMotionSuite {
    static func run() -> Int {
        print("BurnMotionSuite")
        var f = 0
        f += check("true rest: trail off, needle barely alive") {
            try assertEqual(BurnMotion.energy(ratio: 0), 0, accuracy: 1e-12)
            try assertEqual(BurnMotion.needleJitterAmplitude(ratio: 0), 0.15, accuracy: 0.02)
            try assertEqual(BurnMotion.bloomOpacity(ratio: 0), 0, accuracy: 1e-12)
            try assertEqual(BurnMotion.trailOpacity(ratio: 0), 0, accuracy: 1e-12)
            try assertEqual(BurnMotion.needleGlowOpacity(ratio: 0), 0, accuracy: 0.02)
        }
        f += check("brief tier anchors (jitter amp)") {
            // rest edge 0.35 → ~0.35°, cruise mid ~1.0 → between 0.35–0.70
            try assertEqual(BurnMotion.needleJitterAmplitude(ratio: 0.35), 0.35, accuracy: 0.02)
            let cruise = BurnMotion.needleJitterAmplitude(ratio: 1.0)
            try assertTrue(cruise > 0.35 && cruise < 0.75, "cruise amp \(cruise)")
            try assertEqual(BurnMotion.needleJitterAmplitude(ratio: 2.0), 1.80, accuracy: 0.02)
        }
        f += check("brief glow soft-cap ≤0.58 tier") {
            let g0 = BurnMotion.needleGlowOpacity(ratio: 0)
            let g2 = BurnMotion.needleGlowOpacity(ratio: 2.0)
            try assertTrue(g2 > g0, "glow rises")
            try assertEqual(g2, 0.58, accuracy: 0.02)
            let bloom = BurnMotion.bloomOpacity(ratio: 2.0)
            try assertTrue(bloom <= 0.14, "bloom \(bloom)")
        }
        f += check("cruise energy mid-band") {
            let e = BurnMotion.energy(ratio: 1.0)
            try assertTrue(e > 0.2 && e < 0.85, "cruise energy \(e)")
            let redE = BurnMotion.energy(ratio: 2.0)
            try assertTrue(redE > e, "redline > cruise")
            try assertEqual(redE, 1.0, accuracy: 1e-9)
        }
        f += check("period shortens with burn") {
            let pRest = BurnMotion.motionPeriod(ratio: 0.2)
            let pRed = BurnMotion.motionPeriod(ratio: 2.0)
            try assertTrue(pRest > pRed, "period \(pRest) → \(pRed)")
            try assertTrue(pRed >= 0.75 && pRed <= 1.1, "redline period \(pRed)")
        }
        f += check("phase offset desyncs widgets") {
            let a = UUID()
            let b = UUID()
            let oa = BurnMotion.phaseOffset(for: a)
            let ob = BurnMotion.phaseOffset(for: b)
            try assertTrue(oa >= 0.2 && oa <= 2.0, "offset a \(oa)")
            try assertTrue(ob >= 0.2 && ob <= 2.0, "offset b \(ob)")
            // Same id stable.
            try assertEqual(oa, BurnMotion.phaseOffset(for: a), accuracy: 1e-12)
        }
        f += check("overdrive only past cruise") {
            try assertEqual(BurnMotion.overdrive(ratio: 0.5), 0, accuracy: 1e-12)
            try assertEqual(BurnMotion.overdrive(ratio: 1.0), 0, accuracy: 1e-12)
            try assertTrue(BurnMotion.overdrive(ratio: 1.5) > 0.4, "mid od")
            try assertEqual(BurnMotion.overdrive(ratio: 2.0), 1.0, accuracy: 1e-12)
        }
        f += check("cruise pip peaks near 1") {
            let near = BurnMotion.cruisePipBoost(ratio: 1.0)
            let far = BurnMotion.cruisePipBoost(ratio: 0.2)
            try assertTrue(near > far, "near > far")
            try assertTrue(near > 0.2, "near meaningful")
        }
        f += check("jitter respects amp envelope") {
            let amp = BurnMotion.needleJitterAmplitude(ratio: 2.0)
            try assertEqual(amp, 1.80, accuracy: 0.02)
            // Sample many phases — envelope must stay within amp (+tiny float slop).
            var peak = 0.0
            for i in 0..<240 {
                let t = Date(timeIntervalSinceReferenceDate: Double(i) * 0.05)
                let j = abs(BurnMotion.needleJitterDegrees(ratio: 2.0, at: t))
                peak = max(peak, j)
            }
            try assertTrue(peak <= amp + 0.02, "peak \(peak) > amp \(amp)")
            try assertTrue(peak > amp * 0.4, "peak too timid \(peak)")
        }
        f += check("energy non-decreasing along ratio") {
            var prev = BurnMotion.energy(ratio: 0.1)
            for r in stride(from: 0.3, through: 2.0, by: 0.3) {
                let e = BurnMotion.energy(ratio: r)
                try assertTrue(e + 1e-9 >= prev, "\(prev) → \(e) at \(r)")
                prev = e
            }
        }
        return f
    }
}
