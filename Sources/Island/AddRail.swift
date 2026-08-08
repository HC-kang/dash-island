import SwiftUI

/// Trailing chevron that expands a slim dashed skeleton pocket with a centered `+`.
/// Opens after a short dwell (≥500ms) so accidental strip-hover does not grow the body.
struct AddRail: View {
    var onSelectVendor: (any VendorAdapter) -> Void
    var onExpandedChange: (Bool) -> Void

    @State private var expanded = false
    @State private var stripHovered = false
    @State private var openTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?

    static let chevronWidth: CGFloat = 16
    /// ~⅓ of a 100pt slot — narrow dashed chassis for the add pocket.
    static let railWidth: CGFloat = 36
    static var totalExpandedWidth: CGFloat { chevronWidth + railWidth }

    private static let dwellNanos: UInt64 = 500_000_000
    private static let closeGraceNanos: UInt64 = 280_000_000
    private static let cellH = AccountWidget.cellHeight

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.compact.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(stripHovered || expanded ? 0.55 : 0.28))
                .frame(width: Self.chevronWidth, height: Self.cellH)

            ZStack {
                if expanded {
                    Menu {
                        VendorMenuItems(onSelect: onSelectVendor)
                    } label: {
                        ZStack {
                            SlimAddSkeleton()
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .padding(.vertical, 10)
                    .padding(.trailing, 2)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(width: expanded ? Self.railWidth : 0, alignment: .leading)
            .clipped()
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            stripHovered = hovering
            if hovering {
                cancelClose()
                NotificationCenter.default.post(name: .dashIslandRequestKey, object: nil)
                scheduleOpen()
            } else {
                cancelOpen()
                scheduleClose()
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: expanded)
        .onChange(of: expanded) { isOpen in
            onExpandedChange(isOpen)
        }
        .onDisappear {
            cancelOpen()
            cancelClose()
            if expanded {
                expanded = false
                onExpandedChange(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add account")
    }

    private func scheduleOpen() {
        cancelOpen()
        guard !expanded else { return }
        openTask = Task {
            try? await Task.sleep(nanoseconds: Self.dwellNanos)
            guard !Task.isCancelled, stripHovered else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                expanded = true
            }
        }
    }

    private func scheduleClose() {
        cancelClose()
        closeTask = Task {
            try? await Task.sleep(nanoseconds: Self.closeGraceNanos)
            guard !Task.isCancelled else { return }
            if !stripHovered {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    expanded = false
                }
            }
        }
    }

    private func cancelOpen() {
        openTask?.cancel()
        openTask = nil
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }
}

/// Compact dashed chassis matching slot skeletons, sized for the slim add rail.
private struct SlimAddSkeleton: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.055),
                        Color.white.opacity(0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.14),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 3)
                    .frame(width: 22, height: 22)
                    .offset(y: -4)
            }
    }
}
