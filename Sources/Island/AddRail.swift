import SwiftUI

/// Trailing chevron that expands a slim “+” rail on hover.
/// The whole chevron+rail strip keeps the rail open while the pointer is over it.
struct AddRail: View {
    var onSelectVendor: (any VendorAdapter) -> Void
    var onExpandedChange: (Bool) -> Void

    @State private var expanded = false
    @State private var stripHovered = false
    @State private var closeTask: Task<Void, Never>?

    static let chevronWidth: CGFloat = 16
    /// ~⅓ of a 100pt slot.
    static let railWidth: CGFloat = 36
    static var totalExpandedWidth: CGFloat { chevronWidth + railWidth }

    private static let closeGraceNanos: UInt64 = 280_000_000

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.compact.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(stripHovered || expanded ? 0.55 : 0.28))
                .frame(width: Self.chevronWidth, height: AccountWidget.cellSize + 8)

            ZStack {
                if expanded {
                    // Plus only — no "Add" caption, no menu disclosure chevron.
                    Menu {
                        VendorMenuItems(onSelect: onSelectVendor)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                Color.white.opacity(0.12),
                                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                            )
                                    )
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .padding(.vertical, 12)
                    .padding(.trailing, 2)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(width: expanded ? Self.railWidth : 0, alignment: .leading)
            .clipped()
        }
        // Entire strip (chevron + open rail) is one hover surface.
        .contentShape(Rectangle())
        .onHover { hovering in
            stripHovered = hovering
            if hovering {
                cancelClose()
                openRail()
            } else {
                scheduleClose()
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: expanded)
        .onChange(of: expanded) { isOpen in
            onExpandedChange(isOpen)
        }
        .onDisappear {
            cancelClose()
            if expanded {
                expanded = false
                onExpandedChange(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add account")
    }

    private func openRail() {
        cancelClose()
        guard !expanded else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            expanded = true
        }
    }

    private func scheduleClose() {
        cancelClose()
        closeTask = Task {
            try? await Task.sleep(nanoseconds: Self.closeGraceNanos)
            guard !Task.isCancelled else { return }
            // Only collapse if the pointer still isn't on the strip.
            if !stripHovered {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    expanded = false
                }
            }
        }
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }
}
