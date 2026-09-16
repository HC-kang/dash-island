#!/usr/bin/env bash
# Native panel smoke check; uses fake accounts and makes no provider calls.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
cat > "$CHECK_DIR/Check.swift" <<'SWIFT'
import AppKit

@main enum Check {
    @MainActor static func main() {
        _ = NSApplication.shared
        let island = IslandWindowController()
        precondition(island.window.contentView!.acceptsFirstMouse(for: nil),
                     "Inactive island must deliver the first widget click")
        let panel = UsageDetailPanel.shared
        let first = WidgetViewModel(id: UUID(), title: "First", vendorID: "test", tint: .codex,
            primaryFraction: 0, secondaryFraction: nil, usedPrimaryFraction: 0,
            centerPercent: 0, burnRatio: 0, hoverWindows: [], errorCaption: nil,
            isAwaitingFirstSample: false)
        var second = first
        second.id = UUID()
        second.title = "Second"
        panel.toggle(model: first)
        precondition(panel.isOpen && panel.window!.isVisible)
        panel.toggle(model: first)
        precondition(!panel.isOpen && !panel.window!.isVisible)
        panel.toggle(model: first)
        panel.toggle(model: second)
        precondition(panel.isOpen && panel.window!.title == "Second usage")
        panel.show(model: second) // Explicit context-menu Open must stay open.
        precondition(panel.isOpen)
        panel.close()
        panel.toggle(model: second)
        precondition(panel.isOpen)
        panel.close()
        print("PASS: first mouse, open, same-account close, different-account switch, explicit open, reopen")
    }
}
SWIFT
swiftc -parse-as-library -target arm64-apple-macos13.0 -O \
    -framework SwiftUI -framework AppKit -framework Combine -framework Security \
    -framework ServiceManagement -framework CoreGraphics \
    $(find Sources -name '*.swift' ! -path 'Sources/App/App.swift' | sort) \
    "$CHECK_DIR/Check.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
