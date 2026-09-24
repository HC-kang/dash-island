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
# shellcheck source=scripts/check-build.sh
. scripts/check-build.sh
compile_check "$CHECK_DIR/Check.swift" "$CHECK_DIR/check"
"$CHECK_DIR/check"
