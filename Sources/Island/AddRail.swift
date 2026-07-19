import SwiftUI

/// Trailing chevron that, on hover, smoothly expands a slim rail for the add control.
/// Rail width ≈ ⅓–½ of a slot (skeleton) width.
struct AddRail: View {
    var onSelectVendor: (any VendorAdapter) -> Void
    /// Notifies parent so the island black body can grow with the rail.
    var onExpandedChange: (Bool) -> Void

    @State private var expanded = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var chevronHot = false
    @State private var railHot = false

    /// Collapsed strip (chevron only).
    static let chevronWidth: CGFloat = 16
    /// Expanded add pocket — between 1/3 and 1/2 of slot width (100 → ~36).
    static let railWidth: CGFloat = 36
    static var totalExpandedWidth: CGFloat { chevronWidth + railWidth }

    private var open: Bool { expanded || railHot }

    var body: some View {
        HStack(spacing: 0) {
            // Slim chevron always visible.
            Image(systemName: "chevron.compact.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(chevronHot || open ? 0.55 : 0.28))
                .frame(width: Self.chevronWidth, height: AccountWidget.cellSize + 8)
                .contentShape(Rectangle())
                .onHover { hovering in
                    chevronHot = hovering
                    if hovering {
                        openRail()
                    } else {
                        scheduleCloseIfNeeded()
                    }
                }

            // Smooth width reveal for the add control.
            ZStack {
                if open {
                    Menu {
                        VendorMenuItems(onSelect: onSelectVendor)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Add")
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(Color.white.opacity(0.7))
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
                    .padding(.vertical, 10)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(width: open ? Self.railWidth : 0, alignment: .leading)
            .clipped()
            .onHover { hovering in
                railHot = hovering
                if hovering {
                    openRail()
                } else {
                    scheduleCloseIfNeeded()
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: open)
        .onChange(of: open) { isOpen in
            onExpandedChange(isOpen)
        }
        .onDisappear {
            hoverTask?.cancel()
            if expanded || railHot {
                expanded = false
                railHot = false
                onExpandedChange(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add account")
    }

    private func openRail() {
        hoverTask?.cancel()
        hoverTask = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            expanded = true
        }
    }

    private func scheduleCloseIfNeeded() {
        hoverTask?.cancel()
        hoverTask = Task {
            // Small grace so chevron → rail handoff doesn't collapse.
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            if !chevronHot && !railHot {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    expanded = false
                }
            }
        }
    }
}
