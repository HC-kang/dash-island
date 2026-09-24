#!/usr/bin/env bash
# Render regression: weekly/scoped rings must paint when the 5h ring is 0%,
# both at mount and when the values arrive after mount. Fake values, no provider calls.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
cat > "$CHECK_DIR/Check.swift" <<'SWIFT'
import AppKit
import SwiftUI

@MainActor final class Inputs: ObservableObject {
    @Published var secondary: Double? = nil
    @Published var tertiary: Double? = nil
}
struct Probe: View {
    @ObservedObject var inputs: Inputs
    var body: some View {
        HStack(spacing: 0) {
            GaugeRingView(primaryFraction: 0, secondaryFraction: inputs.secondary, tertiaryFraction: inputs.tertiary,
                          centerPercent: 0, burnRatio: 0, tint: .claude, size: 96)
            GaugeRingView(primaryFraction: 0, secondaryFraction: 0.79, tertiaryFraction: 1,
                          centerPercent: 0, burnRatio: 0, tint: .claude, size: 96)
        }.frame(width: 192, height: 96).background(Color.black)
    }
}
@main enum Check {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let inputs = Inputs()
        let host = NSHostingView(rootView: Probe(inputs: inputs))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 200, width: 192, height: 96),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func settle(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        // Steel (weekly) ring pixels in the 96pt cell starting at `x0`.
        func steelPixels(_ x0: Int) -> Int {
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let k = bitmap.pixelsWide / 192
            var count = 0
            for y in 0..<(96 * k) {
                for x in (x0 * k)..<((x0 + 96) * k) {
                    let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if c.blueComponent > 0.4, c.blueComponent > c.redComponent + 0.15 { count += 1 }
                }
            }
            return count
        }
        settle(0.5)
        let mounted = steelPixels(96)
        inputs.secondary = 0.79
        inputs.tertiary = 1
        settle(0.6)
        let late = steelPixels(0)
        print("weekly ring pixels — at mount: \(mounted), after late data: \(late)")
        // Pixel counts scale with the square of the backing scale; 400 at 1x is
        // ~70% of the measured 575, so 1x displays no longer pass by a 15% hair.
        let k = host.bitmapImageRepForCachingDisplay(in: host.bounds)!.pixelsWide / 192
        let minimum = 400 * k * k
        guard mounted > minimum, late > minimum else { print("FAIL: weekly ring blank while 5h is 0% (need > \(minimum))"); exit(1) }
        print("PASS: rings paint with 5h at 0%")
        exit(0)
    }
}
SWIFT
# shellcheck source=scripts/check-build.sh
. scripts/check-build.sh
compile_check "$CHECK_DIR/Check.swift" "$CHECK_DIR/check"
env -u DASHISLAND_DEMO "$CHECK_DIR/check"
