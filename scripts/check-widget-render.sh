#!/usr/bin/env bash
# Isolated SwiftUI render regression; fake widgets, no provider calls or real account edits.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
cat > "$CHECK_DIR/Check.swift" <<'SWIFT'
import AppKit
import SwiftUI

@MainActor final class Samples: ObservableObject {
    @Published var widgets: [WidgetViewModel]
    @Published var expected: [WidgetViewModel]
    @Published var visible = true
    var committed: [AccountID] = []
    init() {
        func widget(_ title: String, _ percent: Int) -> WidgetViewModel {
            WidgetViewModel(id: UUID(), title: title, vendorID: "test", tint: .codex,
                primaryFraction: Double(percent) / 100, secondaryFraction: nil,
                usedPrimaryFraction: Double(percent) / 100, centerPercent: percent,
                burnRatio: 0, hoverWindows: [], errorCaption: nil, isAwaitingFirstSample: false)
        }
        let a = widget("A", 12), b = widget("B", 87), c = widget("C", 45)
        widgets = [a, b, c]
        var updated = b
        updated.centerPercent = 73
        updated.primaryFraction = 0.73
        updated.usedPrimaryFraction = 0.73
        expected = [updated, a, c]
    }
}

struct Probe: View {
    @ObservedObject var samples: Samples
    var body: some View {
        if #available(macOS 15.0, *) {
            content.allowsWindowActivationEvents()
        } else {
            content
        }
    }
    private var content: some View {
        VStack(spacing: 0) {
            if samples.visible {
                GaugeClusterView(widgets: samples.widgets, onOrderCommitted: { samples.committed = $0 })
                    .frame(width: 324, height: 120)
            } else {
                Color.clear.frame(width: 324, height: 120)
            }
            GaugeClusterView(widgets: samples.expected, allowsEditing: false)
                .frame(width: 324, height: 120)
        }.background(Color.black)
    }
}

@main enum Check {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let samples = Samples()
        let host = NSHostingView(rootView: Probe(samples: samples))
        let window = BorderlessFloatingWindow(contentRect: NSRect(x: 40, y: 200, width: 324, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        func settle(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.005)))
            }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        settle(0.025)
        // Reorder and receive fresh usage during the initial 80ms reveal delay.
        samples.widgets = samples.expected
        settle(0.35)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / 324
        var difference = 0.0, samplesRead = 0, bright = 0
        for y in Int(6 * scale)..<Int(86 * scale) {
            for x in Int(10 * scale)..<Int(90 * scale) {
                let a = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let b = bitmap.colorAt(x: x, y: y + Int(120 * scale))!.usingColorSpace(.deviceRGB)!
                difference += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                samplesRead += 3
                if min(b.redComponent, b.greenComponent, b.blueComponent) > 0.7 { bright += 1 }
            }
        }
        let error = difference / Double(samplesRead)
        print("Gauge render difference: \(error); visible text pixels: \(bright)")
        guard bright > 20, error < 0.004 else {
            // Keep the render only on failure, at a path no parallel run shares.
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("dash-widget-render-\(UUID().uuidString).png")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
            print("FAIL: reordered/updated gauge differs from the current-value reference; \(output.path)")
            exit(1)
        }
        print("PASS: reorder and fresh usage during reveal display the current account and values")

        var dragging = false
        let monitor = NotificationCenter.default.addObserver(forName: .dashIslandDragActive, object: nil, queue: .main) {
            dragging = ($0.object as? Bool) ?? false
        }
        defer { NotificationCenter.default.removeObserver(monitor) }
        func mouse(_ type: NSEvent.EventType, x: CGFloat) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 180), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.postEvent(event, atStart: false)
            settle(0.03)
        }
        mouse(.leftMouseDown, x: 50)
        mouse(.leftMouseDragged, x: 65)
        mouse(.leftMouseDragged, x: 80)
        guard dragging else { print("FAIL: native drag did not begin"); exit(1) }
        var replacement = samples.widgets[2]
        replacement.id = UUID()
        replacement.title = "D"
        samples.widgets[2] = replacement // membership changes while the gesture is active
        // Cross the centered-row / scrolling-row boundary during the same drag.
        for title in ["E", "F", "G"] {
            var added = replacement
            added.id = UUID()
            added.title = title
            samples.widgets.append(added)
        }
        settle(0.03)
        mouse(.leftMouseDragged, x: 162)
        mouse(.leftMouseUp, x: 162)
        guard !dragging else { print("FAIL: drop retained mouse capture"); exit(1) }
        samples.expected = [samples.widgets[1], samples.widgets[0]] + samples.widgets.dropFirst(2)
        settle(0.35)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var rowDifference = 0.0
        for y in 0..<Int(120 * scale) {
            for x in 0..<bitmap.pixelsWide {
                let a = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let b = bitmap.colorAt(x: x, y: y + Int(120 * scale))!.usingColorSpace(.deviceRGB)!
                rowDifference += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            }
        }
        rowDifference /= Double(Int(120 * scale) * bitmap.pixelsWide * 3)
        print("Dropped row render difference: \(rowDifference)")
        guard rowDifference < 0.004 else {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("dash-widget-drop-\(UUID().uuidString).png")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
            print("FAIL: drop lost concurrent changes; \(output.path)")
            exit(1)
        }
        mouse(.leftMouseDown, x: 50)
        mouse(.leftMouseDragged, x: 65)
        mouse(.leftMouseDragged, x: 80)
        guard dragging else { print("FAIL: second drag did not begin"); exit(1) }
        let removedID = samples.expected[0].id
        samples.widgets.removeAll { $0.id == removedID }
        settle(0.05)
        guard !dragging else { print("FAIL: removing dragged account retained mouse capture"); exit(1) }
        mouse(.leftMouseUp, x: 80)
        mouse(.leftMouseDown, x: 50)
        mouse(.leftMouseDragged, x: 65)
        mouse(.leftMouseDragged, x: 80)
        guard dragging else { print("FAIL: third drag did not begin"); exit(1) }
        samples.visible = false
        settle(0.05)
        guard !dragging else { print("FAIL: teardown retained mouse capture"); exit(1) }
        print("PASS: native drag retains concurrent changes; account removal and teardown release mouse capture")

        // Auto-scroll: park the dragged widget at a viewport edge; the row must scroll
        // under it so a single drag can reach slots that start off-screen.
        for title in ["H", "I"] {
            var added = replacement
            added.id = UUID()
            added.title = title
            samples.widgets.append(added)
        }
        samples.visible = true
        settle(0.3)
        let before = samples.widgets.map(\.id)
        precondition(before.count == 7)
        mouse(.leftMouseDown, x: 50)
        mouse(.leftMouseDragged, x: 65)
        mouse(.leftMouseDragged, x: 80)
        guard dragging else { print("FAIL: auto-scroll drag did not begin"); exit(1) }
        mouse(.leftMouseDragged, x: 310)
        settle(1.6)
        mouse(.leftMouseUp, x: 310)
        settle(0.1)
        guard !dragging else { print("FAIL: auto-scroll drop retained mouse capture"); exit(1) }
        guard samples.committed == Array(before.dropFirst()) + [before[0]] else {
            print("FAIL: right-edge hold did not scroll to the last slot; got \(samples.committed.map { id in samples.widgets.first { $0.id == id }?.title ?? "?" })")
            exit(1)
        }
        // Row is now scrolled to the end; the moved widget sits in the last visible cell.
        mouse(.leftMouseDown, x: 272)
        mouse(.leftMouseDragged, x: 260)
        mouse(.leftMouseDragged, x: 245)
        guard dragging else { print("FAIL: left auto-scroll drag did not begin"); exit(1) }
        mouse(.leftMouseDragged, x: 10)
        settle(1.6)
        mouse(.leftMouseUp, x: 10)
        settle(0.1)
        guard !dragging else { print("FAIL: left auto-scroll drop retained mouse capture"); exit(1) }
        guard samples.committed == before else {
            print("FAIL: left-edge hold did not scroll back to the first slot; got \(samples.committed.map { id in samples.widgets.first { $0.id == id }?.title ?? "?" })")
            exit(1)
        }
        window.orderOut(nil)
        print("PASS: holding a dragged widget at either viewport edge auto-scrolls the row")
    }
}
SWIFT
# shellcheck source=scripts/check-build.sh
. scripts/check-build.sh
compile_check "$CHECK_DIR/Check.swift" "$CHECK_DIR/check"
DASHISLAND_DEMO=1 "$CHECK_DIR/check"
